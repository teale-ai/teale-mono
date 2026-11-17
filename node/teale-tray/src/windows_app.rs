use std::fs::OpenOptions;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::Context;
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use tray_icon::menu::MenuEvent;
use tray_icon::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, IDYES, MB_DEFBUTTON2, MB_ICONQUESTION, MB_ICONWARNING, MB_OK, MB_SETFOREGROUND,
    MB_TOPMOST, MB_YESNO,
};
use wry::WebViewBuilder;

use crate::shared::{
    append_log, build_tray_menu, control_port_from_config, dispatch_auth_callback, fetch_snapshot,
    forward_ipc_message, handle_native_message, icon_for_state, initial_desktop_url,
    initialization_script, node_url, post, protocol_handler, set_pending_oauth_callback,
    show_window, start_ipc_listener, tooltip_for, AppSnapshot, IconState, IpcMessage, TrayMenu,
};

/// NSSM service name registered by `node/installer/post-install.ps1`.
const NODE_SERVICE_NAME: &str = "TealeNode";
/// How long Quit waits for the service to stop answering. NSSM gives the
/// node 35 s after its console Ctrl+C (`AppStopMethodConsole`, set by the
/// installer) to drain in-flight requests (`shutdown_timeout_seconds`,
/// default 30 s); the rest covers NSSM's later stop methods and the
/// llama-server teardown.
const SERVICE_STOP_TIMEOUT: Duration = Duration::from_secs(60);
/// `CREATE_NO_WINDOW`: the tray is a GUI-subsystem process, so a helper
/// console process would otherwise flash a window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// Exit code the elevation script reports when the stop command never ran
/// (UAC declined, PowerShell could not launch it). Distinguishes that from
/// the stop command's own exit code.
const ELEVATION_FAILED_EXIT_CODE: i32 = 255;

#[derive(Debug, Clone)]
enum UserEvent {
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    Status(Option<AppSnapshot>),
    AuthCallback(String),
    OpenWindow,
    /// The TealeNode service has stopped (or was already stopped): exit the tray.
    Quit,
    /// The user declined the Quit confirmation/UAC prompt, or the service did
    /// not stop: keep running.
    QuitAborted,
}

pub fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let instance = SingleInstance::acquire()?;
    if instance.is_secondary() {
        // The first tray may still be constructing its event loop/listener.
        // Retry through that bounded startup window so simultaneous login-item
        // and direct/deep-link launches reliably hand off instead of opening a
        // second tray (#344 parity for Windows).
        forward_to_primary_with_retry(&IpcMessage::from_args(&args), Duration::from_secs(10))?;
        return Ok(());
    }

    let install_dir = install_dir();
    let config_path = install_dir.join("config").join("teale-node.toml");
    let control_port = control_port_from_config(&config_path);
    let log_path = tray_log_path(&install_dir);

    let initial_auth_callback = args.iter().find(|arg| arg.starts_with("teale://")).cloned();
    let open_on_start =
        args.iter().any(|arg| arg == "--open-window") || initial_auth_callback.is_some();

    let mut event_loop_builder = EventLoopBuilder::<UserEvent>::with_user_event();
    let event_loop = event_loop_builder.build();
    let proxy = event_loop.create_proxy();

    let tray_proxy = proxy.clone();
    TrayIconEvent::set_event_handler(Some(move |event| {
        let _ = tray_proxy.send_event(UserEvent::Tray(event));
    }));

    let menu_proxy = proxy.clone();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = menu_proxy.send_event(UserEvent::Menu(event));
    }));

    let ipc_proxy = proxy.clone();
    start_ipc_listener(move |message| {
        let event = match message.kind.as_str() {
            "authCallback" => message
                .url
                .filter(|url| !url.trim().is_empty())
                .map(UserEvent::AuthCallback),
            "openWindow" => Some(UserEvent::OpenWindow),
            _ => None,
        };
        event.is_none_or(|event| ipc_proxy.send_event(event).is_ok())
    });

    let window = WindowBuilder::new()
        .with_title("Teale")
        .with_visible(open_on_start)
        .with_inner_size(LogicalSize::new(920.0, 700.0))
        .with_min_inner_size(LogicalSize::new(760.0, 580.0))
        .build(&event_loop)
        .context("build Teale companion window")?;

    let ipc_log_path = log_path.clone();
    let init_script = initialization_script("windows", "Windows device", true, control_port);
    let webview = WebViewBuilder::new(&window)
        .with_custom_protocol("teale".into(), protocol_handler)
        .with_initialization_script(&init_script)
        .with_ipc_handler(move |request| {
            handle_native_message(request, control_port, &ipc_log_path)
        })
        .with_url(initial_desktop_url())
        .build()
        .context("build Teale companion webview")?;

    let TrayMenu {
        menu,
        pause: item_pause,
        resume: item_resume,
        open: item_open,
        close_tray: item_close_tray,
        quit: item_quit,
    } = build_tray_menu()?;

    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip("Teale — starting…")
        .with_icon(icon_for_state(IconState::Inactive))
        .build()
        .context("build tray icon")?;

    let poll_proxy = proxy.clone();
    std::thread::spawn(move || loop {
        let snapshot = fetch_snapshot(control_port);
        if poll_proxy.send_event(UserEvent::Status(snapshot)).is_err() {
            break;
        }
        std::thread::sleep(Duration::from_secs(5));
    });

    if let Some(callback_url) = initial_auth_callback {
        let _ = proxy.send_event(UserEvent::AuthCallback(callback_url));
    }

    let mut current_icon = IconState::Inactive;
    let mut quit_in_progress = false;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;

        match event {
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                window.set_visible(false);
            }
            Event::UserEvent(UserEvent::Status(snapshot)) => {
                if quit_in_progress {
                    // Keep the "Stopping…" tooltip until the quit flow resolves.
                    return;
                }
                let (next_icon, tooltip) = tooltip_for(snapshot.as_ref());
                if next_icon != current_icon {
                    let _ = tray.set_icon(Some(icon_for_state(next_icon)));
                    current_icon = next_icon;
                }
                let _ = tray.set_tooltip(Some(tooltip));
            }
            Event::UserEvent(UserEvent::AuthCallback(callback_url)) => {
                let summary = summarize_callback_url(&callback_url);
                append_log(&log_path, &format!("received callback {summary}"));
                set_pending_oauth_callback(&callback_url);
                show_window(&window);
                dispatch_auth_callback(&webview, &callback_url);
            }
            Event::UserEvent(UserEvent::OpenWindow) => show_window(&window),
            Event::UserEvent(UserEvent::Quit) => *control_flow = ControlFlow::Exit,
            Event::UserEvent(UserEvent::QuitAborted) => {
                quit_in_progress = false;
                // The next status poll (≤5 s) restores the live tooltip.
                let _ = tray.set_tooltip(Some("Teale — still running"));
            }
            Event::UserEvent(UserEvent::Menu(event)) => {
                if event.id == item_pause.id() {
                    post(&node_url(control_port, "/v1/app/service/pause"));
                } else if event.id == item_resume.id() {
                    post(&node_url(control_port, "/v1/app/service/resume"));
                } else if event.id == item_open.id() {
                    show_window(&window);
                } else if event.id == item_close_tray.id() {
                    *control_flow = ControlFlow::Exit;
                } else if event.id == item_quit.id() && !quit_in_progress {
                    quit_in_progress = true;
                    let _ = tray.set_tooltip(Some("Teale — Stopping…"));
                    // Confirmation + UAC + service drain can take tens of
                    // seconds; keep the event loop (and the tray icon)
                    // responsive by doing it off-thread.
                    let quit_proxy = proxy.clone();
                    let quit_log_path = log_path.clone();
                    std::thread::spawn(move || {
                        let event = match run_quit_flow(control_port, &quit_log_path) {
                            Ok(()) => UserEvent::Quit,
                            Err(()) => UserEvent::QuitAborted,
                        };
                        let _ = quit_proxy.send_event(event);
                    });
                }
            }
            Event::UserEvent(UserEvent::Tray(e)) if opens_window(&e) => show_window(&window),
            _ => {}
        }
    });
}

/// Left click (release) or double click on the tray icon opens the window.
fn opens_window(event: &TrayIconEvent) -> bool {
    matches!(
        event,
        TrayIconEvent::Click {
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
            ..
        } | TrayIconEvent::DoubleClick {
            button: MouseButton::Left,
            ..
        }
    )
}

/// Install root (`C:\Teale` by default): the tray lives in `<root>\bin`.
fn install_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent()?.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("C:\\Teale"))
}

/// `<install>\logs\tray.log` when this user may write there (admin or dev
/// installs); otherwise the per-user `%LOCALAPPDATA%\Teale\logs\tray.log`,
/// since the hardened install tree is read-only for standard users.
fn tray_log_path(install_dir: &Path) -> PathBuf {
    let preferred = install_dir.join("logs").join("tray.log");
    if can_append(&preferred) {
        return preferred;
    }
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Teale")
        .join("logs")
        .join("tray.log")
}

fn can_append(path: &Path) -> bool {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    options.open(path).is_ok()
}

struct SingleInstance {
    handle: HANDLE,
    secondary: bool,
}

impl SingleInstance {
    fn acquire() -> anyhow::Result<Self> {
        // Local\ scopes ownership to the interactive Windows session. That is
        // where duplicate tray icons/windows can exist; the machine-level node
        // service remains independently owned by NSSM.
        let handle = unsafe { CreateMutexW(None, false, w!("Local\\TealeTraySingleInstance")) }
            .context("create Teale tray single-instance mutex")?;
        // CreateMutexW succeeds for both the first and later callers; the
        // immediate last-error value distinguishes an existing owner.
        let secondary = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        Ok(Self { handle, secondary })
    }

    fn is_secondary(&self) -> bool {
        self.secondary
    }
}

impl Drop for SingleInstance {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.handle);
        }
    }
}

fn forward_to_primary_with_retry(message: &IpcMessage, timeout: Duration) -> anyhow::Result<()> {
    let started = Instant::now();
    loop {
        match forward_ipc_message(message) {
            Ok(()) => return Ok(()),
            Err(_) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(error) => return Err(error).context("primary Teale tray did not accept IPC"),
        }
    }
}

/// "Quit Teale" from the tray menu: confirm, stop the machine-level
/// `TealeNode` service (which also ends the llama-server it spawned and frees
/// the model's memory), then let the caller exit the tray.
///
/// The tray runs unelevated per user while the service is owned by the
/// Service Control Manager, so the stop goes through a UAC-elevated helper.
/// `Err(())` means nothing was stopped and the tray must keep running — the
/// user already saw why (they declined, or a dialog explained the failure).
fn run_quit_flow(control_port: u16, log_path: &Path) -> Result<(), ()> {
    let confirmed = unsafe {
        MessageBoxW(
            None,
            w!("Quit Teale?\n\n\
                This stops the Teale Node service, frees the memory used by the \
                loaded model, and removes the tray icon. You stop earning credits \
                until Teale starts again.\n\n\
                Teale starts again automatically the next time Windows starts.\n\n\
                Windows will ask for administrator approval to stop the service."),
            w!("Quit Teale"),
            MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_SETFOREGROUND | MB_TOPMOST,
        )
    };
    if confirmed != IDYES {
        return Err(());
    }

    match stop_node_service(control_port) {
        Ok(()) => Ok(()),
        Err(reason) => {
            append_log(log_path, &format!("quit: service stop failed: {reason}"));
            let text = to_wide(&format!(
                "Teale is still running.\n\n\
                 The Teale Node service could not be stopped:\n{reason}\n\n\
                 You can pause supply from the tray menu instead, or stop the \
                 \"Teale Node\" service from Windows Services as an administrator."
            ));
            unsafe {
                MessageBoxW(
                    None,
                    PCWSTR(text.as_ptr()),
                    w!("Quit Teale"),
                    MB_OK | MB_ICONWARNING | MB_SETFOREGROUND | MB_TOPMOST,
                );
            }
            Err(())
        }
    }
}

/// Stop the node service with elevation and wait until its local control API
/// stops answering. Returns a user-facing reason on failure.
fn stop_node_service(control_port: u16) -> Result<(), String> {
    if !node_service_responding(control_port, Duration::from_secs(1)) {
        // Nothing to stop (service already down); still fine to quit.
        return Ok(());
    }

    let bin_dir = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf));
    let (program, args) = service_stop_command(bin_dir.as_deref());
    let script = elevated_stop_script(&program, &args);

    let output = Command::new(powershell_path())
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-WindowStyle",
            "Hidden",
            "-Command",
            script.as_str(),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|error| format!("could not launch PowerShell ({error})"))?;

    if output.status.code() == Some(ELEVATION_FAILED_EXIT_CODE) {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr.trim();
        return Err(if detail.is_empty() {
            "administrator approval was not given.".to_string()
        } else {
            detail.to_string()
        });
    }
    // Any other exit code (including a non-zero one from nssm/sc, e.g. when
    // the service is mid-transition) is judged by the outcome below.

    wait_until_service_stopped(control_port, SERVICE_STOP_TIMEOUT).map_err(|()| {
        format!(
            "the service was still answering after {} seconds.",
            SERVICE_STOP_TIMEOUT.as_secs()
        )
    })
}

/// Prefer the bundled NSSM (installed next to teale-tray.exe in
/// `C:\Teale\bin`): `nssm stop` waits for the service and tears down the
/// llama-server process tree. Fall back to `sc.exe stop`, which only requests
/// the stop; the caller polls for the outcome either way.
fn service_stop_command(bin_dir: Option<&Path>) -> (PathBuf, Vec<String>) {
    let nssm = bin_dir.map(|dir| dir.join("nssm.exe"));
    let program = match nssm {
        Some(path) if path.is_file() => path,
        _ => PathBuf::from("sc.exe"),
    };
    (
        program,
        vec!["stop".to_string(), NODE_SERVICE_NAME.to_string()],
    )
}

/// PowerShell script that runs `program args` through `Start-Process -Verb
/// RunAs` (UAC prompt) and relays its exit code. Exits with
/// `ELEVATION_FAILED_EXIT_CODE` if the process never started, which is how a
/// declined UAC prompt surfaces ("The operation was canceled by the user").
fn elevated_stop_script(program: &Path, args: &[String]) -> String {
    let program = ps_single_quote(&program.to_string_lossy());
    let args = args
        .iter()
        .map(String::as_str)
        .map(ps_single_quote)
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "$ErrorActionPreference = 'Stop'; \
         try {{ $p = Start-Process -FilePath {program} -ArgumentList @({args}) \
         -Verb RunAs -WindowStyle Hidden -Wait -PassThru }} \
         catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit {failed} }}; \
         if ($null -eq $p.ExitCode) {{ exit 0 }}; exit $p.ExitCode",
        failed = ELEVATION_FAILED_EXIT_CODE
    )
}

/// Single-quoted PowerShell string literal (the only escape is `'` → `''`).
fn ps_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn powershell_path() -> PathBuf {
    std::env::var_os("SystemRoot")
        .map(|root| {
            PathBuf::from(root)
                .join("System32")
                .join("WindowsPowerShell")
                .join("v1.0")
                .join("powershell.exe")
        })
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("powershell.exe"))
}

/// Any HTTP answer (even an error status) means the node process is up; only
/// a transport failure (connection refused, timeout) counts as stopped.
fn node_service_responding(control_port: u16, timeout: Duration) -> bool {
    let url = node_url(control_port, "/v1/app");
    !matches!(
        ureq::get(&url).timeout(timeout).call(),
        Err(ureq::Error::Transport(_))
    )
}

fn wait_until_service_stopped(control_port: u16, timeout: Duration) -> Result<(), ()> {
    let deadline = Instant::now() + timeout;
    loop {
        if !node_service_responding(control_port, Duration::from_secs(1)) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// NUL-terminated UTF-16 for Win32 string parameters built at runtime.
fn to_wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn summarize_callback_url(callback_url: &str) -> String {
    let mut keys = Vec::new();
    let without_fragment = callback_url.split('#').next().unwrap_or(callback_url);
    let fragment = callback_url.split_once('#').map(|(_, fragment)| fragment);
    let base = without_fragment
        .split_once('?')
        .map(|(base, _)| base)
        .unwrap_or(without_fragment);
    if let Some(query) = without_fragment.split_once('?').map(|(_, query)| query) {
        keys.extend(
            query
                .split('&')
                .filter_map(|pair| pair.split('=').next())
                .map(str::to_string),
        );
    }
    if let Some(fragment) = fragment {
        keys.extend(
            fragment
                .split('&')
                .filter_map(|pair| pair.split('=').next())
                .map(str::to_string),
        );
    }
    keys.sort();
    keys.dedup();
    format!("{base} keys=[{}]", keys.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_stop_prefers_bundled_nssm() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "teale-tray-quit-test-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();

        let (program, args) = service_stop_command(Some(&dir));
        assert_eq!(program, PathBuf::from("sc.exe"));
        assert_eq!(args, vec!["stop".to_string(), "TealeNode".to_string()]);

        let nssm = dir.join("nssm.exe");
        std::fs::write(&nssm, b"").unwrap();
        let (program, args) = service_stop_command(Some(&dir));
        assert_eq!(program, nssm);
        assert_eq!(args, vec!["stop".to_string(), "TealeNode".to_string()]);

        let (program, _) = service_stop_command(None);
        assert_eq!(program, PathBuf::from("sc.exe"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn elevated_stop_script_quotes_and_relays_exit_code() {
        let script = elevated_stop_script(
            Path::new("C:\\Teale's bin\\nssm.exe"),
            &["stop".to_string(), "TealeNode".to_string()],
        );
        assert!(script.contains("-FilePath 'C:\\Teale''s bin\\nssm.exe'"));
        assert!(script.contains("-ArgumentList @('stop','TealeNode')"));
        assert!(script.contains("-Verb RunAs"));
        assert!(script.contains("-Wait -PassThru"));
        assert!(script.contains("exit 255"));
        assert!(script.ends_with("exit $p.ExitCode"));
    }

    #[test]
    fn wide_strings_are_nul_terminated() {
        let wide = to_wide("Teale");
        assert_eq!(wide.last(), Some(&0));
        assert_eq!(wide.len(), "Teale".encode_utf16().count() + 1);
    }

    #[test]
    fn callback_summary_lists_keys_not_values() {
        let summary = summarize_callback_url("teale://auth/callback?code=secret#state=x");
        assert_eq!(summary, "teale://auth/callback keys=[code,state]");
    }
}

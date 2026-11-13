use std::borrow::Cow;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, IDYES, MB_DEFBUTTON2, MB_ICONQUESTION, MB_ICONWARNING, MB_OK, MB_SETFOREGROUND,
    MB_TOPMOST, MB_YESNO,
};
use wry::{
    http::{header::CONTENT_TYPE, Request, Response},
    WebViewBuilder,
};

const INDEX_HTML: &str = include_str!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/index.html"
);
const APP_CSS: &[u8] = include_bytes!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/app.css"
);
const APP_JS: &[u8] = include_bytes!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/app.js"
);
const SUPABASE_JS: &[u8] = include_bytes!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/supabase-js-2.105.4.min.js"
);
const IPC_PORT: u16 = 11438;
const REMOTE_DESKTOP_URL: &str = "https://teale.com/docs/desktop-companion/index.html";
/// Local node control API (the tray's status source; also used to confirm the
/// service is really down after a Quit).
const NODE_STATUS_URL: &str = "http://127.0.0.1:11437/v1/app";
/// NSSM service name registered by `node/installer/post-install.ps1`.
const NODE_SERVICE_NAME: &str = "TealeNode";
/// How long Quit waits for the service to stop answering. The node drains
/// in-flight requests for up to `shutdown_timeout_seconds` (default 30 s)
/// before NSSM/SCM report it stopped, so leave headroom beyond that.
const SERVICE_STOP_TIMEOUT: Duration = Duration::from_secs(60);
/// `CREATE_NO_WINDOW`: the tray is a GUI-subsystem process, so a helper
/// console process would otherwise flash a window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// Exit code the elevation script reports when the stop command never ran
/// (UAC declined, PowerShell could not launch it). Distinguishes that from
/// the stop command's own exit code.
const ELEVATION_FAILED_EXIT_CODE: i32 = 255;
static PENDING_OAUTH_CALLBACK: OnceLock<Mutex<Option<String>>> = OnceLock::new();

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

#[derive(Debug, Clone, Deserialize, Default)]
struct AppSnapshot {
    #[serde(default)]
    service_state: String,
    #[serde(default)]
    state_reason: Option<String>,
    #[serde(default)]
    loaded_model_id: Option<String>,
    #[serde(default)]
    active_transfer: Option<TransferSnapshot>,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct TransferSnapshot {
    model_id: String,
    #[serde(default)]
    bytes_downloaded: u64,
    #[serde(default)]
    bytes_total: Option<u64>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum IconState {
    Serving,
    Inactive,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct IpcMessage {
    kind: String,
    #[serde(default)]
    url: Option<String>,
}

pub fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let instance = SingleInstance::acquire()?;
    if instance.is_secondary() {
        // The first tray may still be constructing its event loop/listener.
        // Retry through that bounded startup window so simultaneous login-item
        // and direct/deep-link launches reliably hand off instead of opening a
        // second tray (#344 parity for Windows).
        let message = args
            .iter()
            .find(|arg| arg.starts_with("teale://"))
            .cloned()
            .map(|url| IpcMessage {
                kind: "authCallback".into(),
                url: Some(url),
            })
            .unwrap_or(IpcMessage {
                kind: "openWindow".into(),
                url: None,
            });
        forward_to_primary_with_retry(message, Duration::from_secs(10))?;
        return Ok(());
    }

    let initial_auth_callback = args.iter().find(|arg| arg.starts_with("teale://")).cloned();
    let launch_without_args = args.len() <= 1;
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

    start_auth_callback_listener(proxy.clone());

    let window = WindowBuilder::new()
        .with_title("Teale")
        .with_visible(open_on_start)
        .with_inner_size(LogicalSize::new(920.0, 700.0))
        .with_min_inner_size(LogicalSize::new(760.0, 580.0))
        .build(&event_loop)
        .context("build Teale companion window")?;

    let initial_url = initial_desktop_url();
    let webview = WebViewBuilder::new(&window)
        .with_custom_protocol("teale".into(), protocol_handler)
        .with_initialization_script(&initialization_script())
        .with_ipc_handler(|payload| {
            if let Ok(message) = serde_json::from_str::<NativeMessage>(payload.body()) {
                if message.kind == "openExternal" {
                    if let Some(url) = message.url {
                        let _ = webbrowser::open(&url);
                    }
                } else if message.kind == "authLog" {
                    if let Some(text) = message.message {
                        append_auth_log(&text);
                    }
                }
            }
        })
        .with_url(&initial_url)
        .build()
        .context("build Teale companion webview")?;

    let item_pause = MenuItem::new("Pause supply", true, None);
    let item_resume = MenuItem::new("Resume supply", true, None);
    let item_open = MenuItem::new("Open Teale", true, None);
    let item_close_tray = MenuItem::new("Close tray icon (Teale keeps supplying)", true, None);
    let item_quit = MenuItem::new("Quit Teale (stop supplying)", true, None);

    let tray_menu = Menu::new();
    tray_menu.append(&item_pause)?;
    tray_menu.append(&item_resume)?;
    tray_menu.append(&PredefinedMenuItem::separator())?;
    tray_menu.append(&item_open)?;
    tray_menu.append(&PredefinedMenuItem::separator())?;
    tray_menu.append(&item_close_tray)?;
    tray_menu.append(&item_quit)?;

    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(tray_menu))
        .with_menu_on_left_click(false)
        .with_tooltip("Teale — starting…")
        .with_icon(icon_for_state(IconState::Inactive))
        .build()
        .context("build tray icon")?;

    let poll_proxy = proxy.clone();
    std::thread::spawn(move || loop {
        let snapshot = fetch_snapshot();
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
                let _ = window.set_visible(false);
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
                append_auth_log(&format!(
                    "received callback {}",
                    summarize_callback_url(&callback_url)
                ));
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
                    post("http://127.0.0.1:11437/v1/app/service/pause");
                } else if event.id == item_resume.id() {
                    post("http://127.0.0.1:11437/v1/app/service/resume");
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
                    std::thread::spawn(move || {
                        let event = match run_quit_flow() {
                            Ok(()) => UserEvent::Quit,
                            Err(()) => UserEvent::QuitAborted,
                        };
                        let _ = quit_proxy.send_event(event);
                    });
                }
            }
            Event::UserEvent(UserEvent::Tray(event)) => match event {
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                }
                | TrayIconEvent::DoubleClick {
                    button: MouseButton::Left,
                    ..
                } => show_window(&window),
                _ => {}
            },
            _ => {}
        }
    });
}

#[derive(Debug, Deserialize)]
struct NativeMessage {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    message: Option<String>,
}

fn protocol_handler(request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let host = request.uri().host().unwrap_or_default();
    let raw_path = request.uri().path();
    let path = if matches!(raw_path, "/" | "") || (host == "auth" && raw_path == "/callback") {
        "index.html"
    } else if raw_path == "/auth/callback" {
        "index.html"
    } else {
        raw_path.trim_start_matches('/')
    };

    let (body, mime, status) = match path {
        "index.html" => (INDEX_HTML.as_bytes().to_vec(), "text/html", 200),
        "app.css" => (APP_CSS.to_vec(), "text/css", 200),
        "app.js" => (APP_JS.to_vec(), "text/javascript", 200),
        "supabase-js-2.105.4.min.js" => (SUPABASE_JS.to_vec(), "text/javascript", 200),
        "auth/pending" => {
            let body = serde_json::to_vec(&serde_json::json!({
                "url": take_pending_oauth_callback()
            }))
            .unwrap_or_else(|_| b"{\"url\":null}".to_vec());
            (body, "application/json", 200)
        }
        _ => (b"Not Found".to_vec(), "text/plain", 404),
    };

    Response::builder()
        .header(CONTENT_TYPE, mime)
        .header("Access-Control-Allow-Origin", "*")
        .header(
            "Access-Control-Allow-Headers",
            "Content-Type, Accept, Authorization",
        )
        .header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        .header("Access-Control-Allow-Private-Network", "true")
        .status(status)
        .body(Cow::Owned(body))
        .expect("custom protocol response")
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

fn forward_to_primary_with_retry(message: IpcMessage, timeout: Duration) -> anyhow::Result<()> {
    let started = Instant::now();
    loop {
        match forward_ipc_message(message.clone()) {
            Ok(()) => return Ok(()),
            Err(error) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(100));
                let _ = error;
            }
            Err(error) => return Err(error).context("primary Teale tray did not accept IPC"),
        }
    }
}

fn show_window(window: &tao::window::Window) {
    window.set_visible(true);
    window.set_minimized(false);
    let _ = window.set_focus();
}

/// "Quit Teale" from the tray menu: confirm, stop the machine-level
/// `TealeNode` service (which also ends the llama-server it spawned and frees
/// the model's memory), then let the caller exit the tray.
///
/// The tray runs unelevated per user while the service is owned by the
/// Service Control Manager, so the stop goes through a UAC-elevated helper.
/// `Err(())` means nothing was stopped and the tray must keep running — the
/// user already saw why (they declined, or a dialog explained the failure).
fn run_quit_flow() -> Result<(), ()> {
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

    match stop_node_service() {
        Ok(()) => Ok(()),
        Err(reason) => {
            append_auth_log(&format!("quit: service stop failed: {reason}"));
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
fn stop_node_service() -> Result<(), String> {
    if !node_service_responding(Duration::from_secs(1)) {
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

    wait_until_service_stopped(SERVICE_STOP_TIMEOUT).map_err(|()| {
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
    (program, vec!["stop".to_string(), NODE_SERVICE_NAME.to_string()])
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
fn node_service_responding(timeout: Duration) -> bool {
    !matches!(
        ureq::get(NODE_STATUS_URL).timeout(timeout).call(),
        Err(ureq::Error::Transport(_))
    )
}

fn wait_until_service_stopped(timeout: Duration) -> Result<(), ()> {
    let deadline = Instant::now() + timeout;
    loop {
        if !node_service_responding(Duration::from_secs(1)) {
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

fn start_auth_callback_listener(proxy: tao::event_loop::EventLoopProxy<UserEvent>) {
    std::thread::spawn(move || {
        let listener = match TcpListener::bind(("127.0.0.1", IPC_PORT)) {
            Ok(listener) => listener,
            Err(_) => return,
        };

        for stream in listener.incoming() {
            let Ok(mut stream) = stream else {
                continue;
            };

            let mut payload = String::new();
            if stream.read_to_string(&mut payload).is_err() {
                continue;
            }
            let Ok(message) = serde_json::from_str::<IpcMessage>(payload.trim()) else {
                continue;
            };

            let result = match message.kind.as_str() {
                "authCallback" => message
                    .url
                    .filter(|url| !url.trim().is_empty())
                    .map(UserEvent::AuthCallback)
                    .map(|event| proxy.send_event(event)),
                "openWindow" => Some(proxy.send_event(UserEvent::OpenWindow)),
                _ => None,
            };

            if matches!(result, Some(Err(_))) {
                break;
            }
        }
    });
}

fn forward_ipc_message(message: IpcMessage) -> anyhow::Result<()> {
    let mut stream =
        TcpStream::connect(("127.0.0.1", IPC_PORT)).context("connect to running Teale tray")?;
    let payload = serde_json::to_string(&message).context("serialize tray IPC message")?;
    stream
        .write_all(payload.as_bytes())
        .context("forward IPC message to tray")?;
    Ok(())
}

fn dispatch_auth_callback(webview: &wry::WebView, callback_url: &str) {
    let Ok(payload) = serde_json::to_string(callback_url) else {
        return;
    };
    let script = format!(
        r#"
        window.__tealePendingOAuthCallbackUrl = {payload};
        try {{
          window.localStorage.setItem("__teale_pending_oauth_callback", {payload});
        }} catch (_error) {{}}
        if (typeof window.__tealeHandleOAuthCallback === "function") {{
          window.__tealeHandleOAuthCallback({payload});
        }}
        "#
    );
    let _ = webview.evaluate_script(&script);
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

fn append_auth_log(line: &str) {
    let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open("C:\\Teale\\logs\\tray-oauth.log")
    else {
        return;
    };
    let _ = writeln!(file, "{line}");
}

fn pending_oauth_callback() -> &'static Mutex<Option<String>> {
    PENDING_OAUTH_CALLBACK.get_or_init(|| Mutex::new(None))
}

fn set_pending_oauth_callback(callback_url: &str) {
    if let Ok(mut pending) = pending_oauth_callback().lock() {
        *pending = Some(callback_url.to_string());
    }
}

fn take_pending_oauth_callback() -> Option<String> {
    pending_oauth_callback()
        .lock()
        .ok()
        .and_then(|mut pending| pending.take())
}

fn fetch_snapshot() -> Option<AppSnapshot> {
    ureq::get("http://127.0.0.1:11437/v1/app")
        .timeout(Duration::from_secs(3))
        .call()
        .ok()
        .and_then(|r| r.into_json::<AppSnapshot>().ok())
}

fn post(url: &str) {
    let _ = ureq::post(url).timeout(Duration::from_secs(3)).call();
}

fn initialization_script() -> String {
    let payload = serde_json::json!({
        "apiBase": "http://127.0.0.1:11437",
        "platform": "windows",
        "shellMode": true,
        "deviceLabel": "Windows device",
        "chatTransport": "app-proxy",
        "routes": {
            "authPending": "teale://localhost/auth/pending",
            "bundledApp": "teale://localhost/"
        }
    });
    format!("window.__TEALE_DESKTOP_CONFIG__ = {payload};")
}

fn initial_desktop_url() -> String {
    let remote_url = std::env::var("TEALE_DESKTOP_WEB_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| REMOTE_DESKTOP_URL.to_string());
    if remote_desktop_available(&remote_url) {
        remote_url
    } else {
        "teale://localhost".to_string()
    }
}

fn remote_desktop_available(url: &str) -> bool {
    ureq::get(url)
        .timeout(Duration::from_secs(2))
        .call()
        .map(|response| response.status() >= 200 && response.status() < 300)
        .unwrap_or(false)
}

fn tooltip_for(snapshot: Option<&AppSnapshot>) -> (IconState, String) {
    let Some(snapshot) = snapshot else {
        return (
            IconState::Inactive,
            "Teale — Disconnected\nThe service may still be starting.".to_string(),
        );
    };

    let icon = if snapshot.service_state == "serving" {
        IconState::Serving
    } else {
        IconState::Inactive
    };

    let headline = match snapshot.service_state.as_str() {
        "serving" => "Teale — Serving",
        "offline" => "Teale — Offline",
        "downloading" => "Teale — Downloading",
        "loading" => "Teale — Loading",
        "paused_user" => "Teale — Paused",
        "paused_battery" => "Teale — Waiting for AC",
        "needs_model" => "Teale — Choose a model",
        "starting" => "Teale — Starting",
        _ => "Teale — Not Ready",
    };

    let detail = if let Some(transfer) = &snapshot.active_transfer {
        match transfer.bytes_total {
            Some(total) if total > 0 => format!(
                "{} {:.0}%",
                transfer.model_id,
                (transfer.bytes_downloaded as f64 / total as f64) * 100.0
            ),
            _ => transfer.model_id.clone(),
        }
    } else if snapshot.service_state == "offline" {
        snapshot
            .state_reason
            .clone()
            .or_else(|| snapshot.loaded_model_id.clone())
            .unwrap_or_else(|| "Open Teale to manage supply.".to_string())
    } else if let Some(model_id) = &snapshot.loaded_model_id {
        model_id.clone()
    } else {
        snapshot
            .state_reason
            .clone()
            .unwrap_or_else(|| "Open Teale to manage supply.".to_string())
    };

    (icon, format!("{headline}\n{detail}"))
}

fn icon_for_state(state: IconState) -> Icon {
    match state {
        IconState::Serving => leaf_icon(0x2d, 0xb7, 0x67),
        IconState::Inactive => leaf_icon(0x8a, 0x94, 0x9e),
    }
}

/// Final Teale leaf mark, status-tinted for the Windows tray. Keeping the
/// alpha mask in-tree avoids an image-decoder/runtime asset dependency.
fn leaf_icon(r: u8, g: u8, b: u8) -> Icon {
    const SIZE: u32 = 32;
    const ALPHA: &[u8; (SIZE * SIZE) as usize] =
        include_bytes!("../assets/teale-leaf-alpha-32.bin");
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for alpha in ALPHA {
        rgba.extend_from_slice(&[r, g, b, *alpha]);
    }
    Icon::from_rgba(rgba, SIZE, SIZE).expect("build Teale leaf icon")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaf_mask_is_embedded_at_expected_size() {
        const ALPHA: &[u8; 32 * 32] = include_bytes!("../assets/teale-leaf-alpha-32.bin");
        assert!(ALPHA.iter().any(|alpha| *alpha == 0));
        assert!(ALPHA.iter().any(|alpha| *alpha > 200));
    }

    #[test]
    fn tooltip_marks_serving_green() {
        let snapshot = AppSnapshot {
            service_state: "serving".into(),
            state_reason: None,
            loaded_model_id: Some("canary".into()),
            active_transfer: None,
        };
        let (state, text) = tooltip_for(Some(&snapshot));
        assert!(matches!(state, IconState::Serving));
        assert!(text.contains("Serving"));
    }

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
}

//! Linux desktop shell: the same tray icon, tooltip and menu as Windows
//! (via `tray-icon`, which uses libayatana-appindicator / StatusNotifierItem)
//! plus the companion window.
//!
//! * Closing the window hides it while the tray icon is up; launching Teale
//!   again (or "Open Teale" in the menu) brings it back.
//! * "Close tray icon" exits this process only; the node keeps supplying.
//! * "Quit Teale" stops the per-user systemd unit `teale-node.service` when
//!   it exists (`systemctl --user stop`, which lets the node drain), then
//!   exits. Without that unit it just exits.
//! * Without an appindicator host or library the shell falls back to a plain
//!   window and exits when it is closed.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::Context;
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use tray_icon::menu::MenuEvent;
use tray_icon::{TrayIcon, TrayIconBuilder};
use wry::WebViewBuilder;

use crate::shared::{
    append_log, build_tray_menu, control_port_from_config, dispatch_auth_callback, fetch_snapshot,
    forward_ipc_message, handle_native_message, icon_for_state, initial_desktop_url,
    initialization_script, node_url, post, protocol_handler, set_pending_oauth_callback,
    show_window, start_ipc_listener, tooltip_for, AppSnapshot, IconState, IpcMessage, TrayMenu,
};

const NODE_UNIT: &str = "teale-node.service";

#[derive(Debug, Clone)]
enum UserEvent {
    Menu(MenuEvent),
    Status(Option<AppSnapshot>),
    AuthCallback(String),
    OpenWindow,
    Quit,
}

pub fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    // A running shell owns the IPC port: hand the request over and exit.
    if forward_ipc_message(&IpcMessage::from_args(&args)).is_ok() {
        return Ok(());
    }

    let control_port = control_port_from_config(&config_dir().join("teale-node.toml"));
    let log_path = state_dir().join("logs").join("tray.log");
    let initial_auth_callback = args.iter().find(|arg| arg.starts_with("teale://")).cloned();
    let open_on_start = !args.iter().any(|arg| arg == "--hidden");

    let mut event_loop_builder = EventLoopBuilder::<UserEvent>::with_user_event();
    let event_loop = event_loop_builder.build();
    let proxy = event_loop.create_proxy();

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
        .with_window_icon(crate::app_icon::large())
        .with_visible(open_on_start)
        .with_inner_size(LogicalSize::new(920.0, 700.0))
        .with_min_inner_size(LogicalSize::new(760.0, 580.0))
        .build(&event_loop)
        .context("build Teale companion window")?;

    let ipc_log_path = log_path.clone();
    let init_script = initialization_script("linux", "Linux device", true, control_port);
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
    let tray = build_tray_icon(menu);
    if tray.is_none() {
        append_log(&log_path, "tray icon unavailable; running window-only");
        if !open_on_start {
            show_window(&window);
        }
    }

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
                if tray.is_some() {
                    window.set_visible(false);
                } else {
                    *control_flow = ControlFlow::Exit;
                }
            }
            Event::UserEvent(UserEvent::Status(snapshot)) => {
                let Some(tray) = tray.as_ref() else {
                    return;
                };
                if quit_in_progress {
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
                set_pending_oauth_callback(&callback_url);
                show_window(&window);
                dispatch_auth_callback(&webview, &callback_url);
            }
            Event::UserEvent(UserEvent::OpenWindow) => show_window(&window),
            Event::UserEvent(UserEvent::Quit) => *control_flow = ControlFlow::Exit,
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
                    if let Some(tray) = tray.as_ref() {
                        let _ = tray.set_tooltip(Some("Teale — Stopping…"));
                    }
                    // `systemctl stop` waits for the node's drain; keep the
                    // event loop responsive meanwhile.
                    let quit_proxy = proxy.clone();
                    std::thread::spawn(move || {
                        stop_node_unit();
                        let _ = quit_proxy.send_event(UserEvent::Quit);
                    });
                }
            }
            _ => {}
        }
    });
}

/// Create the tray icon. libappindicator is loaded at runtime and panics
/// when it is missing, so treat a panic like any other failure and fall
/// back to window-only mode.
fn build_tray_icon(menu: tray_icon::menu::Menu) -> Option<TrayIcon> {
    let builder = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("Teale — starting…")
        .with_icon(icon_for_state(IconState::Inactive));
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || builder.build()))
        .ok()
        .and_then(Result::ok)
}

/// Stop the per-user node unit if the Linux installer created one.
fn stop_node_unit() {
    let unit_exists = Command::new("systemctl")
        .args(["--user", "cat", NODE_UNIT])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if unit_exists {
        let _ = Command::new("systemctl")
            .args(["--user", "stop", NODE_UNIT])
            .status();
    }
}

fn xdg_dir(var: &str, home_fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir)
                .join(home_fallback)
        })
}

/// `$XDG_CONFIG_HOME/teale`, where `install.sh` writes `teale-node.toml`.
fn config_dir() -> PathBuf {
    xdg_dir("XDG_CONFIG_HOME", ".config").join("teale")
}

/// `$XDG_STATE_HOME/teale`, next to the node log written by the unit.
fn state_dir() -> PathBuf {
    xdg_dir("XDG_STATE_HOME", ".local/state").join("teale")
}

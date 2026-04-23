use std::borrow::Cow;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

use anyhow::Context;
use serde::Deserialize;
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use wry::{
    http::{header::CONTENT_TYPE, Request, Response},
    WebViewBuilder,
};

const INDEX_HTML: &str = include_str!("../assets/index.html");
const APP_CSS: &[u8] = include_bytes!("../assets/app.css");
const APP_JS: &[u8] = include_bytes!("../assets/app.js");
const AUTH_CALLBACK_PORT: u16 = 11438;

#[derive(Debug, Clone)]
enum UserEvent {
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    Status(Option<AppSnapshot>),
    AuthCallback(String),
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

pub fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let initial_auth_callback = args.iter().find(|arg| arg.starts_with("teale://")).cloned();
    if let Some(callback_url) = initial_auth_callback.as_deref() {
        if forward_auth_callback(callback_url).is_ok() {
            return Ok(());
        }
    }

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

    let webview = WebViewBuilder::new(&window)
        .with_custom_protocol("teale".into(), protocol_handler)
        .with_ipc_handler(|payload| {
            if let Ok(message) = serde_json::from_str::<NativeMessage>(payload.body()) {
                if message.kind == "openExternal" {
                    if let Some(url) = message.url {
                        let _ = webbrowser::open(&url);
                    }
                }
            }
        })
        .with_url("teale://localhost")
        .build()
        .context("build Teale companion webview")?;

    let item_pause = MenuItem::new("Pause supply", true, None);
    let item_resume = MenuItem::new("Resume supply", true, None);
    let item_open = MenuItem::new("Open Teale", true, None);
    let item_close_tray = MenuItem::new("Close tray icon (Teale keeps supplying)", true, None);

    let tray_menu = Menu::new();
    tray_menu.append(&item_pause)?;
    tray_menu.append(&item_resume)?;
    tray_menu.append(&PredefinedMenuItem::separator())?;
    tray_menu.append(&item_open)?;
    tray_menu.append(&PredefinedMenuItem::separator())?;
    tray_menu.append(&item_close_tray)?;

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
                let (next_icon, tooltip) = tooltip_for(snapshot.as_ref());
                if next_icon != current_icon {
                    let _ = tray.set_icon(Some(icon_for_state(next_icon)));
                    current_icon = next_icon;
                }
                let _ = tray.set_tooltip(Some(tooltip));
            }
            Event::UserEvent(UserEvent::AuthCallback(callback_url)) => {
                show_window(&window);
                dispatch_auth_callback(&webview, &callback_url);
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

    let (body, mime) = match path {
        "index.html" => (INDEX_HTML.as_bytes().to_vec(), "text/html"),
        "app.css" => (APP_CSS.to_vec(), "text/css"),
        "app.js" => (APP_JS.to_vec(), "text/javascript"),
        _ => (b"Not Found".to_vec(), "text/plain"),
    };

    Response::builder()
        .header(CONTENT_TYPE, mime)
        .status(if matches!(path, "index.html" | "app.css" | "app.js") {
            200
        } else {
            404
        })
        .body(Cow::Owned(body))
        .expect("custom protocol response")
}

fn show_window(window: &tao::window::Window) {
    window.set_visible(true);
    window.set_minimized(false);
    let _ = window.set_focus();
}

fn start_auth_callback_listener(proxy: tao::event_loop::EventLoopProxy<UserEvent>) {
    std::thread::spawn(move || {
        let listener = match TcpListener::bind(("127.0.0.1", AUTH_CALLBACK_PORT)) {
            Ok(listener) => listener,
            Err(_) => return,
        };

        for stream in listener.incoming() {
            let Ok(mut stream) = stream else {
                continue;
            };

            let mut url = String::new();
            if stream.read_to_string(&mut url).is_err() {
                continue;
            }
            let callback_url = url.trim().to_string();
            if callback_url.is_empty() {
                continue;
            }
            if proxy
                .send_event(UserEvent::AuthCallback(callback_url))
                .is_err()
            {
                break;
            }
        }
    });
}

fn forward_auth_callback(callback_url: &str) -> anyhow::Result<()> {
    let mut stream = TcpStream::connect(("127.0.0.1", AUTH_CALLBACK_PORT))
        .context("connect to running Teale tray auth relay")?;
    stream
        .write_all(callback_url.as_bytes())
        .context("forward auth callback to tray")?;
    Ok(())
}

fn dispatch_auth_callback(webview: &wry::WebView, callback_url: &str) {
    let Ok(payload) = serde_json::to_string(callback_url) else {
        return;
    };
    let script = format!("window.__tealeHandleOAuthCallback({payload});");
    let _ = webview.evaluate_script(&script);
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
        IconState::Serving => head_icon(0x2d, 0xb7, 0x67),
        IconState::Inactive => head_icon(0xd9, 0x3c, 0x35),
    }
}

fn head_icon(r: u8, g: u8, b: u8) -> Icon {
    const SIZE: u32 = 32;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE as i32 {
        for x in 0..SIZE as i32 {
            let dx = x - 13;
            let dy = y - 13;
            let skull = dx * dx + (dy * dy * 5) / 4 <= 100;
            let jaw = x > 12 && x < 23 && y > 16 && y < 29;
            let face_cut = x > 20 && y > 8 && y < 22 && (x + y) > 34;
            let neck = x > 11 && x < 16 && y > 22;
            let brain_cut = (x - 12) * (x - 12) + (y - 11) * (y - 11) <= 16
                || (x - 16) * (x - 16) + (y - 11) * (y - 11) <= 12
                || (x - 14) * (x - 14) + (y - 8) * (y - 8) <= 10;
            let inside = (skull || jaw || neck) && !face_cut;
            if inside {
                rgba.extend_from_slice(&[r, g, b, if brain_cut { 0x90 } else { 0xFF }]);
            } else {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
            }
        }
    }
    Icon::from_rgba(rgba, SIZE, SIZE).expect("build head icon")
}

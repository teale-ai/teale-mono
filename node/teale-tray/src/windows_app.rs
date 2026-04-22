use std::borrow::Cow;
use std::io::Read;
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

#[derive(Debug, Clone)]
enum UserEvent {
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    Status(Option<AppSnapshot>),
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
    let open_on_start = std::env::args().any(|arg| arg == "--open-window");

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

    let window = WindowBuilder::new()
        .with_title("Teale")
        .with_visible(open_on_start)
        .with_inner_size(LogicalSize::new(920.0, 700.0))
        .with_min_inner_size(LogicalSize::new(760.0, 580.0))
        .build(&event_loop)
        .context("build Teale companion window")?;

    let _webview = WebViewBuilder::new(&window)
        .with_custom_protocol("teale".into(), protocol_handler)
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

fn protocol_handler(request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    if request.uri().path().starts_with("/api/") {
        return proxy_api_request(request);
    }

    let path = match request.uri().path() {
        "/" | "" => "index.html",
        other => other.trim_start_matches('/'),
    };

    let (body, mime) = match path {
        "index.html" => (INDEX_HTML.as_bytes().to_vec(), "text/html"),
        "app.css" => (APP_CSS.to_vec(), "text/css"),
        "app.js" => (APP_JS.to_vec(), "text/javascript"),
        _ => (b"Not Found".to_vec(), "text/plain"),
    };

    Response::builder()
        .header(CONTENT_TYPE, mime)
        .status(if path == "index.html" || path == "app.css" || path == "app.js" {
            200
        } else {
            404
        })
        .body(Cow::Owned(body))
        .expect("custom protocol response")
}

fn proxy_api_request(request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let api_path = request
        .uri()
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or(request.uri().path());
    let upstream_url = format!("http://127.0.0.1:11437{}", api_path.trim_start_matches("/api"));
    let mut upstream = ureq::request(request.method().as_str(), &upstream_url)
        .timeout(Duration::from_secs(10));

    if let Some(content_type) = request
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
    {
        upstream = upstream.set(CONTENT_TYPE.as_str(), content_type);
    }

    let result = match request.method().as_str() {
        "GET" | "OPTIONS" => upstream.call(),
        _ => upstream.send_bytes(request.body()),
    };

    match result {
        Ok(response) => response_to_protocol(response),
        Err(ureq::Error::Status(_, response)) => response_to_protocol(response),
        Err(ureq::Error::Transport(err)) => Response::builder()
            .header(CONTENT_TYPE, "application/json")
            .status(502)
            .body(Cow::Owned(
                format!(r#"{{"error":"{}"}}"#, err).into_bytes(),
            ))
            .expect("proxy error response"),
    }
}

fn response_to_protocol(response: ureq::Response) -> Response<Cow<'static, [u8]>> {
    let status = response.status();
    let content_type = response
        .header("Content-Type")
        .unwrap_or("application/json")
        .to_string();
    let mut reader = response.into_reader();
    let mut body = Vec::new();
    let _ = reader.read_to_end(&mut body);

    Response::builder()
        .header(CONTENT_TYPE, content_type)
        .status(status)
        .body(Cow::Owned(body))
        .expect("proxy response")
}

fn show_window(window: &tao::window::Window) {
    window.set_visible(true);
    window.set_minimized(false);
    let _ = window.set_focus();
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
                rgba.extend_from_slice(&[
                    r,
                    g,
                    b,
                    if brain_cut { 0x90 } else { 0xFF },
                ]);
            } else {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
            }
        }
    }
    Icon::from_rgba(rgba, SIZE, SIZE).expect("build head icon")
}

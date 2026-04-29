use std::borrow::Cow;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
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
const IPC_PORT: u16 = 11438;
const REMOTE_DESKTOP_URL: &str = "https://teale.com/docs/desktop-companion/index.html";
static PENDING_OAUTH_CALLBACK: OnceLock<Mutex<Option<String>>> = OnceLock::new();

#[derive(Debug, Clone)]
enum UserEvent {
    AuthCallback(String),
    OpenWindow,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct IpcMessage {
    kind: String,
    #[serde(default)]
    url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NativeMessage {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    url: Option<String>,
}

pub fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let initial_auth_callback = args.iter().find(|arg| arg.starts_with("teale://")).cloned();
    if let Some(callback_url) = initial_auth_callback.as_deref() {
        if forward_ipc_message(IpcMessage {
            kind: "authCallback".into(),
            url: Some(callback_url.to_string()),
        })
        .is_ok()
        {
            return Ok(());
        }
    }

    if initial_auth_callback.is_none() && args.len() <= 1 {
        if forward_ipc_message(IpcMessage {
            kind: "openWindow".into(),
            url: None,
        })
        .is_ok()
        {
            return Ok(());
        }
    }

    let mut event_loop_builder = EventLoopBuilder::<UserEvent>::with_user_event();
    let event_loop = event_loop_builder.build();
    let proxy = event_loop.create_proxy();

    start_auth_callback_listener(proxy.clone());

    let window = WindowBuilder::new()
        .with_title("Teale")
        .with_visible(true)
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
                }
            }
        })
        .with_url(&initial_url)
        .build()
        .context("build Teale companion webview")?;

    if let Some(callback_url) = initial_auth_callback {
        let _ = proxy.send_event(UserEvent::AuthCallback(callback_url));
    }

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;

        match event {
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => *control_flow = ControlFlow::Exit,
            Event::UserEvent(UserEvent::AuthCallback(callback_url)) => {
                set_pending_oauth_callback(&callback_url);
                show_window(&window);
                dispatch_auth_callback(&webview, &callback_url);
            }
            Event::UserEvent(UserEvent::OpenWindow) => show_window(&window),
            _ => {}
        }
    });
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

fn show_window(window: &tao::window::Window) {
    window.set_visible(true);
    window.set_minimized(false);
    let _ = window.set_focus();
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
    let mut stream = TcpStream::connect(("127.0.0.1", IPC_PORT))
        .context("connect to running Teale desktop shell")?;
    let payload = serde_json::to_string(&message).context("serialize desktop shell IPC message")?;
    stream
        .write_all(payload.as_bytes())
        .context("forward IPC message to desktop shell")?;
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

fn initialization_script() -> String {
    let payload = serde_json::json!({
        "apiBase": "http://127.0.0.1:11437",
        "platform": "linux",
        "deviceLabel": "Linux device",
        "chatTransport": "app-proxy",
        "routes": {
            "authPending": "teale://localhost/auth/pending"
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

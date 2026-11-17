//! Code shared by the Windows and Linux desktop shells: the bundled companion
//! UI, the tray menu/tooltip/icon, the node control-API client and the
//! single-instance IPC listener.

use std::borrow::Cow;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tray_icon::menu::{Menu, MenuItem, PredefinedMenuItem};
use tray_icon::Icon;
use wry::http::{header::CONTENT_TYPE, Request, Response};

const INDEX_HTML: &str = include_str!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/index.html"
);
const APP_CSS: &[u8] = include_bytes!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/app.css"
);
const APP_JS: &[u8] = include_bytes!(
    "../../../mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/app.js"
);

/// Single-instance hand-off port. Distinct from every teale-node default
/// (11436 llama, 11437 control, 11438 ds4, 11439 privacy helper, 11440 mnn).
pub const IPC_PORT: u16 = 11441;
/// teale-node's default `[control].port`.
pub const DEFAULT_CONTROL_PORT: u16 = 11437;
/// URL the bundled companion UI is served from (custom protocol).
pub const BUNDLED_UI_URL: &str = "teale://localhost";
/// Rotate the tray log once it grows past this size.
const LOG_MAX_BYTES: u64 = 1024 * 1024;

static PENDING_OAUTH_CALLBACK: OnceLock<Mutex<Option<String>>> = OnceLock::new();

// ---------------------------------------------------------------------------
// Node control API
// ---------------------------------------------------------------------------

/// `[control].port` from the node's TOML, or the default when the file or
/// the key is missing.
pub fn control_port_from_config(path: &Path) -> u16 {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| control_port_from_toml(&text))
        .unwrap_or(DEFAULT_CONTROL_PORT)
}

fn control_port_from_toml(text: &str) -> Option<u16> {
    let value: toml::Value = toml::from_str(text).ok()?;
    let port = value.get("control")?.get("port")?.as_integer()?;
    u16::try_from(port).ok()
}

pub fn node_url(control_port: u16, path: &str) -> String {
    format!("http://127.0.0.1:{control_port}{path}")
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AppSnapshot {
    #[serde(default)]
    pub service_state: String,
    #[serde(default)]
    pub state_reason: Option<String>,
    #[serde(default)]
    pub loaded_model_id: Option<String>,
    #[serde(default)]
    pub active_transfer: Option<TransferSnapshot>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct TransferSnapshot {
    pub model_id: String,
    #[serde(default)]
    pub bytes_downloaded: u64,
    #[serde(default)]
    pub bytes_total: Option<u64>,
}

pub fn fetch_snapshot(control_port: u16) -> Option<AppSnapshot> {
    ureq::get(&node_url(control_port, "/v1/app"))
        .timeout(Duration::from_secs(3))
        .call()
        .ok()
        .and_then(|r| r.into_json::<AppSnapshot>().ok())
}

pub fn post(url: &str) {
    let _ = ureq::post(url).timeout(Duration::from_secs(3)).call();
}

// ---------------------------------------------------------------------------
// Tray icon, tooltip and menu
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IconState {
    Serving,
    Inactive,
}

pub fn tooltip_for(snapshot: Option<&AppSnapshot>) -> (IconState, String) {
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

pub fn icon_for_state(state: IconState) -> Icon {
    match state {
        IconState::Serving => leaf_icon(0x2d, 0xb7, 0x67),
        IconState::Inactive => leaf_icon(0x8a, 0x94, 0x9e),
    }
}

/// Final Teale leaf mark, status-tinted for the tray. Keeping the alpha mask
/// in-tree avoids an image-decoder/runtime asset dependency.
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

/// The tray menu, identical on Windows and Linux.
pub struct TrayMenu {
    pub menu: Menu,
    pub pause: MenuItem,
    pub resume: MenuItem,
    pub open: MenuItem,
    pub close_tray: MenuItem,
    pub quit: MenuItem,
}

pub fn build_tray_menu() -> anyhow::Result<TrayMenu> {
    let pause = MenuItem::new("Pause supply", true, None);
    let resume = MenuItem::new("Resume supply", true, None);
    let open = MenuItem::new("Open Teale", true, None);
    let close_tray = MenuItem::new("Close tray icon (Teale keeps supplying)", true, None);
    let quit = MenuItem::new("Quit Teale (stop supplying)", true, None);

    let menu = Menu::new();
    menu.append(&pause)?;
    menu.append(&resume)?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&open)?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&close_tray)?;
    menu.append(&quit)?;

    Ok(TrayMenu {
        menu,
        pause,
        resume,
        open,
        close_tray,
        quit,
    })
}

// ---------------------------------------------------------------------------
// Companion web UI
// ---------------------------------------------------------------------------

/// The UI the webview loads: always the bundled copy, unless a developer
/// points `TEALE_DESKTOP_WEB_URL` at another build (the node must be started
/// with the same variable so it accepts that origin).
pub fn initial_desktop_url() -> String {
    desktop_web_url_override().unwrap_or_else(|| BUNDLED_UI_URL.to_string())
}

fn desktop_web_url_override() -> Option<String> {
    std::env::var("TEALE_DESKTOP_WEB_URL")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// `scheme://host[:port]` of an absolute URL.
fn web_origin(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    (!scheme.is_empty() && !authority.is_empty()).then(|| format!("{scheme}://{authority}"))
}

pub fn initialization_script(
    platform: &str,
    device_label: &str,
    shell_mode: bool,
    control_port: u16,
) -> String {
    let payload = serde_json::json!({
        "apiBase": node_url(control_port, ""),
        "platform": platform,
        "shellMode": shell_mode,
        "deviceLabel": device_label,
        "chatTransport": "app-proxy",
        "routes": {
            "authPending": "teale://localhost/auth/pending",
            "bundledApp": "teale://localhost/"
        }
    });
    format!("window.__TEALE_DESKTOP_CONFIG__ = {payload};")
}

pub fn protocol_handler(request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let host = request.uri().host().unwrap_or_default();
    let raw_path = request.uri().path();
    let path = if matches!(raw_path, "/" | "")
        || raw_path == "/auth/callback"
        || (host == "auth" && raw_path == "/callback")
    {
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

    let mut response = Response::builder().header(CONTENT_TYPE, mime);
    // Same-origin for the bundled UI. Only a developer override page (a
    // different origin) needs CORS to read `auth/pending`.
    if let Some(origin) = desktop_web_url_override().and_then(|url| web_origin(&url)) {
        response = response
            .header("Access-Control-Allow-Origin", origin)
            .header("Vary", "Origin");
    }
    response
        .status(status)
        .body(Cow::Owned(body))
        .expect("custom protocol response")
}

/// True when the page that sent an IPC message is the bundled UI (wry maps
/// the custom protocol to `teale://localhost` on WebKitGTK and to
/// `http(s)://teale.localhost` on WebView2).
fn is_bundled_page(uri: &wry::http::Uri) -> bool {
    uri.scheme_str() == Some("teale") || uri.host() == Some("teale.localhost")
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

/// Messages the web UI posts to the native shell (`window.ipc.postMessage`).
pub fn handle_native_message(request: Request<String>, control_port: u16, log_path: &Path) {
    let Ok(message) = serde_json::from_str::<NativeMessage>(request.body()) else {
        return;
    };
    match message.kind.as_str() {
        "openExternal" => {
            if let Some(url) = message.url.filter(|url| is_web_url(url)) {
                let _ = webbrowser::open(&url);
            }
        }
        // Diagnostics only from our own bundled page, never a remote one.
        "authLog" if is_bundled_page(request.uri()) => {
            if let Some(text) = message.message {
                append_log(log_path, &text);
            }
        }
        // Gateway email sign-in: the node holds the session, so sign-out
        // is a node call.
        "authSignOut" => post(&node_url(control_port, "/v1/app/auth/logout")),
        _ => {}
    }
}

fn is_web_url(url: &str) -> bool {
    let lower = url.trim_start().to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

pub fn dispatch_auth_callback(webview: &wry::WebView, callback_url: &str) {
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

pub fn set_pending_oauth_callback(callback_url: &str) {
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

pub fn show_window(window: &tao::window::Window) {
    window.set_visible(true);
    window.set_minimized(false);
    window.set_focus();
}

// ---------------------------------------------------------------------------
// Single-instance IPC
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IpcMessage {
    pub kind: String,
    #[serde(default)]
    pub url: Option<String>,
}

impl IpcMessage {
    /// What a second launch with these arguments asks the first instance to do.
    pub fn from_args(args: &[String]) -> Self {
        match args.iter().find(|arg| arg.starts_with("teale://")) {
            Some(url) => Self {
                kind: "authCallback".into(),
                url: Some(url.clone()),
            },
            None => Self {
                kind: "openWindow".into(),
                url: None,
            },
        }
    }
}

/// Listen for hand-offs from later launches. `on_message` returns false once
/// the event loop is gone, which stops the listener.
pub fn start_ipc_listener<F>(on_message: F)
where
    F: Fn(IpcMessage) -> bool + Send + 'static,
{
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
            if !on_message(message) {
                break;
            }
        }
    });
}

pub fn forward_ipc_message(message: &IpcMessage) -> anyhow::Result<()> {
    let mut stream =
        TcpStream::connect(("127.0.0.1", IPC_PORT)).context("connect to running Teale shell")?;
    let payload = serde_json::to_string(message).context("serialize shell IPC message")?;
    stream
        .write_all(payload.as_bytes())
        .context("forward IPC message to shell")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

/// Append one line to the tray log, rotating to `<name>.1` past 1 MiB.
pub fn append_log(path: &Path, line: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::metadata(path).is_ok_and(|meta| meta.len() > LOG_MAX_BYTES) {
        let _ = std::fs::rename(path, rotated_log_path(path));
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
}

fn rotated_log_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".1");
    path.with_file_name(name)
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
        assert_eq!(state, IconState::Serving);
        assert!(text.contains("Serving"));
        let (state, text) = tooltip_for(None);
        assert_eq!(state, IconState::Inactive);
        assert!(text.contains("Disconnected"));
    }

    #[test]
    fn control_port_comes_from_node_config() {
        let toml = "[relay]\nurl = \"x\"\n\n[control]\nport = 12000\n";
        assert_eq!(control_port_from_toml(toml), Some(12000));
        assert_eq!(control_port_from_toml("[relay]\nurl = \"x\"\n"), None);
        assert_eq!(control_port_from_toml("[control]\nport = 99999\n"), None);
        let missing = Path::new("/definitely/not/here/teale-node.toml");
        assert_eq!(control_port_from_config(missing), DEFAULT_CONTROL_PORT);
    }

    #[test]
    fn web_origin_strips_path() {
        let url = "https://teale.com/docs/desktop-companion/index.html";
        assert_eq!(web_origin(url).as_deref(), Some("https://teale.com"));
        let local = "http://localhost:5173?x=1";
        assert_eq!(web_origin(local).as_deref(), Some("http://localhost:5173"));
        assert_eq!(web_origin("not a url"), None);
    }

    #[test]
    fn bundled_page_detection() {
        let bundled = ["teale://localhost/", "http://teale.localhost/index.html"];
        for uri in bundled {
            let uri: wry::http::Uri = uri.parse().expect("uri");
            assert!(is_bundled_page(&uri));
        }
        let remote: wry::http::Uri = "https://teale.com/".parse().expect("uri");
        assert!(!is_bundled_page(&remote));
    }

    #[test]
    fn only_web_urls_open_externally() {
        assert!(is_web_url("https://github.com/login"));
        assert!(!is_web_url("file:///C:/Windows/System32/calc.exe"));
        assert!(!is_web_url("ms-settings:privacy"));
    }

    #[test]
    fn log_rotates_past_cap() {
        let dir = std::env::temp_dir().join(format!("teale-tray-log-{}", std::process::id()));
        let path = dir.join("tray.log");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, vec![b'x'; (LOG_MAX_BYTES + 1) as usize]).unwrap();
        append_log(&path, "fresh");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "fresh\n");
        assert!(rotated_log_path(&path).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn second_launch_forwards_callback_or_open() {
        let args = ["teale-tray", "teale://auth/callback?x"].map(String::from);
        let message = IpcMessage::from_args(&args);
        assert_eq!(message.kind, "authCallback");
        let message = IpcMessage::from_args(&["teale-tray".to_string()]);
        assert_eq!(message.kind, "openWindow");
        assert!(message.url.is_none());
    }
}

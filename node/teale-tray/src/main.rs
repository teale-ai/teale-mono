//! Teale Tray — system-tray companion for teale-node.
//!
//! Talks to the local status endpoint exposed by teale-node (default
//! `http://127.0.0.1:11437`) to show the contributor what the service is
//! doing: supplying / paused / on battery, with a tooltip summary of
//! today's request count and credits earned.
//!
//! This binary is **per-user**, not a service — it starts at login via an
//! Inno Setup `[Icons]` shortcut dropped into the user's Startup folder.
//! The service itself (NSSM-wrapped teale-node.exe) is machine-level and
//! keeps running even when the tray is quit.

#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use serde::Deserialize;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIconBuilder, TrayIconEvent};

/// Matches the JSON shape produced by teale-node's status_server.
#[derive(Debug, Clone, Deserialize, Default)]
struct Status {
    state: String,
    #[serde(default)]
    supplying_since: Option<String>,
    #[serde(default)]
    requests_today: u64,
    #[serde(default)]
    credits_today: i64,
    #[serde(default)]
    on_ac: Option<bool>,
    #[serde(default)]
    paused_reason: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum IconState {
    Supplying = 0,
    PausedBattery = 1,
    PausedUser = 2,
    Error = 3,
}

fn status_url() -> String {
    std::env::var("TEALE_STATUS_URL").unwrap_or_else(|_| "http://127.0.0.1:11437/status".into())
}

fn pause_url() -> String {
    status_url().replace("/status", "/pause")
}

fn resume_url() -> String {
    status_url().replace("/status", "/resume")
}

/// Best-effort fetch of current status. Returns `None` on network error;
/// the tray surfaces that as the "Error" icon until the next successful
/// poll.
fn fetch_status() -> Option<Status> {
    ureq::get(&status_url())
        .timeout(Duration::from_secs(3))
        .call()
        .ok()
        .and_then(|r| r.into_json::<Status>().ok())
}

fn post(url: &str) {
    let _ = ureq::post(url).timeout(Duration::from_secs(3)).call();
}

/// Map the backend's state string to the user-facing icon.
fn map_state(s: &Status) -> IconState {
    match s.state.as_str() {
        "supplying" => IconState::Supplying,
        "paused" => match s.paused_reason.as_deref() {
            Some("battery") => IconState::PausedBattery,
            Some("user") => IconState::PausedUser,
            _ => IconState::PausedUser,
        },
        "error" => IconState::Error,
        _ => IconState::Error,
    }
}

/// Build a 16x16 solid-color icon. Simple enough that we don't need to
/// bundle PNG assets for the pilot; the tray is still instantly
/// recognizable by color (green/yellow/gray/red).
fn solid_icon(r: u8, g: u8, b: u8) -> Icon {
    const SIZE: u32 = 16;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE {
        for x in 0..SIZE {
            // Soft circle for a friendlier look than a square pixel blob.
            let cx = x as i32 - SIZE as i32 / 2;
            let cy = y as i32 - SIZE as i32 / 2;
            let d2 = cx * cx + cy * cy;
            let inside = d2 <= ((SIZE as i32 / 2) - 1).pow(2);
            if inside {
                rgba.push(r);
                rgba.push(g);
                rgba.push(b);
                rgba.push(0xFF);
            } else {
                rgba.push(0);
                rgba.push(0);
                rgba.push(0);
                rgba.push(0);
            }
        }
    }
    Icon::from_rgba(rgba, SIZE, SIZE).expect("build icon from rgba")
}

fn icon_for_state(state: IconState) -> Icon {
    match state {
        IconState::Supplying => solid_icon(0x34, 0xC7, 0x59),      // green
        IconState::PausedBattery => solid_icon(0xFF, 0xCC, 0x00),  // yellow
        IconState::PausedUser => solid_icon(0x8E, 0x8E, 0x93),     // gray
        IconState::Error => solid_icon(0xFF, 0x3B, 0x30),          // red
    }
}

fn tooltip_for(status: &Status) -> String {
    match map_state(status) {
        IconState::Supplying => format!(
            "Teale — Supplying\n{} requests · {} credits today",
            status.requests_today, status.credits_today
        ),
        IconState::PausedBattery => {
            "Teale — Paused (on battery)\nPlug in AC to resume supply.".to_string()
        }
        IconState::PausedUser => "Teale — Paused\nRight-click → Resume".to_string(),
        IconState::Error => {
            "Teale — Disconnected\nService may be starting. Check logs.".to_string()
        }
    }
}

fn main() -> anyhow::Result<()> {
    // Menu items. `MenuItem::new(_, enabled, accelerator)`.
    let item_pause = MenuItem::new("Pause supply", true, None);
    let item_resume = MenuItem::new("Resume supply", true, None);
    let item_dashboard = MenuItem::new("Open Teale dashboard", true, None);
    let item_quit = MenuItem::new("Quit (service keeps running)", true, None);

    let tray_menu = Menu::new();
    tray_menu.append(&item_pause)?;
    tray_menu.append(&item_resume)?;
    tray_menu.append(&PredefinedMenuItem::separator())?;
    tray_menu.append(&item_dashboard)?;
    tray_menu.append(&PredefinedMenuItem::separator())?;
    tray_menu.append(&item_quit)?;

    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(tray_menu))
        .with_tooltip("Teale — starting…")
        .with_icon(icon_for_state(IconState::Error))
        .build()?;

    // Menu-event receiver runs on a separate thread's channel — poll it
    // from the main message loop below.
    let menu_rx = MenuEvent::receiver();
    let tray_rx = TrayIconEvent::receiver();

    // Status polling thread. Sends (IconState, tooltip) to the main thread,
    // which owns the TrayIcon handle and applies the updates — TrayIcon
    // isn't Send on Windows (it holds an HWND), so we can't move it.
    let (status_tx, status_rx) = mpsc::channel::<(IconState, String)>();
    {
        let status_tx = status_tx.clone();
        thread::spawn(move || loop {
            let update = match fetch_status() {
                Some(s) => (map_state(&s), tooltip_for(&s)),
                None => (
                    IconState::Error,
                    "Teale — Disconnected\nService may be starting. Check logs.".to_string(),
                ),
            };
            if status_tx.send(update).is_err() {
                break; // main thread gone — exit the poller
            }
            thread::sleep(Duration::from_secs(5));
        });
    }

    let mut current_icon = IconState::Error;

    // Windows message loop — tray-icon requires a HWND message pump to
    // deliver click / menu events. Without this the icon renders but
    // menu clicks never fire.
    #[cfg(target_os = "windows")]
    {
        use windows::Win32::UI::WindowsAndMessaging::{
            DispatchMessageW, GetMessageW, TranslateMessage, MSG, WM_QUIT,
        };
        let mut msg: MSG = unsafe { std::mem::zeroed() };
        loop {
            let got = unsafe { GetMessageW(&mut msg, None, 0, 0) };
            // -1 on error; 0 means WM_QUIT — either way we exit the loop.
            if got.0 <= 0 {
                break;
            }
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            // Apply any queued status updates from the polling thread.
            while let Ok((state, tip)) = status_rx.try_recv() {
                if state != current_icon {
                    let _ = tray.set_icon(Some(icon_for_state(state)));
                    current_icon = state;
                }
                let _ = tray.set_tooltip(Some(tip));
            }
            // Drain menu/tray channels opportunistically between Win32 messages.
            while let Ok(event) = menu_rx.try_recv() {
                if event.id == item_pause.id() {
                    post(&pause_url());
                } else if event.id == item_resume.id() {
                    post(&resume_url());
                } else if event.id == item_dashboard.id() {
                    let _ = open_url("https://teale.com/supply");
                } else if event.id == item_quit.id() {
                    // Post WM_QUIT so GetMessage returns 0 and we fall out.
                    unsafe {
                        use windows::Win32::UI::WindowsAndMessaging::PostQuitMessage;
                        PostQuitMessage(0);
                    }
                }
            }
            // TrayIconEvent is fired on left-click etc.; we don't act on
            // left-click for the pilot but drain the channel so it doesn't
            // fill up.
            while let Ok(_) = tray_rx.try_recv() {}
            if msg.message == WM_QUIT {
                break;
            }
        }
    }

    // Non-Windows platforms: not supported for the pilot (partner fleet is
    // Windows-only). If we later ship a macOS tray, integrate with AppKit's
    // run loop here.
    #[cfg(not(target_os = "windows"))]
    {
        eprintln!("teale-tray currently supports Windows only. Exiting.");
    }

    Ok(())
}

#[cfg(target_os = "windows")]
fn open_url(url: &str) -> std::io::Result<()> {
    std::process::Command::new("cmd")
        .args(["/C", "start", "", url])
        .spawn()
        .map(|_| ())
}

#[cfg(not(target_os = "windows"))]
fn open_url(_url: &str) -> std::io::Result<()> {
    Ok(())
}

#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

#[cfg(target_os = "windows")]
mod windows_app;

#[cfg(target_os = "windows")]
fn main() -> anyhow::Result<()> {
    windows_app::run()
}

#[cfg(not(target_os = "windows"))]
fn main() -> anyhow::Result<()> {
    eprintln!("teale-tray currently supports Windows only. Exiting.");
    Ok(())
}

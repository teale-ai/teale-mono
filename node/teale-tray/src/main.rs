#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

#[cfg(target_os = "windows")]
mod windows_app;

#[cfg(target_os = "linux")]
mod linux_app;

#[cfg(target_os = "windows")]
fn main() -> anyhow::Result<()> {
    windows_app::run()
}

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux_app::run()
}

#[cfg(all(not(target_os = "windows"), not(target_os = "linux")))]
fn main() -> anyhow::Result<()> {
    eprintln!("teale-tray currently supports Windows and Linux only. Exiting.");
    Ok(())
}

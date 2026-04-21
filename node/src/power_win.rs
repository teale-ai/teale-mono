//! Windows-specific power management for end-user-laptop supply nodes.
//!
//! Two behaviors end-user-laptop contributors need:
//!   1. Keep supplying with the lid closed on AC. Windows' default is
//!      "lid close → sleep", which suspends teale-node along with the rest
//!      of the system. The NSSM service alone isn't enough: the OS can
//!      still enter sleep, and `powercfg` changes are separately done by
//!      the installer. Here we hold a system wake-lock while a request is
//!      in-flight so an unexpected sleep never interrupts it.
//!   2. Pause on battery. Running inference on DC power is a trust
//!      violation — the user's battery should belong to the user. We poll
//!      `GetSystemPowerStatus` and the supervisor uses `is_on_ac()` to
//!      gate whether the node advertises itself as healthy.

#![cfg(windows)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tracing::{info, warn};
use windows::Win32::System::Power::{
    GetSystemPowerStatus, SetThreadExecutionState, ES_AWAYMODE_REQUIRED, ES_CONTINUOUS,
    ES_SYSTEM_REQUIRED, EXECUTION_STATE, SYSTEM_POWER_STATUS,
};

/// RAII handle — while this value is alive, Windows will not enter sleep
/// because of user inactivity. Drop it to release the wake-lock (the OS
/// resumes normal idle/sleep timeouts).
pub struct WakeLock {
    _private: (),
}

impl WakeLock {
    /// Acquire a system-level wake-lock. Call when a request starts serving.
    /// Safe to call repeatedly — Windows tracks the execution state on the
    /// calling thread; the last flag set wins. We always set `ES_CONTINUOUS`
    /// so the state persists across calls.
    ///
    /// No `ES_DISPLAY_REQUIRED` — the screen can go dark, which is what
    /// contributors actually want ("lid closed, screen off, keeps working").
    pub fn acquire() -> Self {
        // Safety: SetThreadExecutionState is a read-only OS state toggle; no
        // buffers are written, no aliasing concerns.
        unsafe {
            let _ = SetThreadExecutionState(
                ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED,
            );
        }
        Self { _private: () }
    }
}

impl Drop for WakeLock {
    fn drop(&mut self) {
        // Release the lock — reset to ES_CONTINUOUS alone, which clears the
        // system-required / away-mode flags. Per Microsoft docs this is the
        // idiomatic way to stop holding the machine awake.
        unsafe {
            let _ = SetThreadExecutionState(ES_CONTINUOUS);
        }
    }
}

/// Current AC power state. Returns `None` if the OS can't tell (which
/// happens on a few corporate VDI images where the battery driver is
/// stubbed out); treat Unknown as on-AC (safer default for desktops).
pub fn is_on_ac() -> Option<bool> {
    let mut status = SYSTEM_POWER_STATUS::default();
    // Safety: GetSystemPowerStatus writes into the provided out-param only;
    // it's a standard OS query.
    let ok = unsafe { GetSystemPowerStatus(&mut status as *mut _) };
    if ok.is_err() {
        return None;
    }
    match status.ACLineStatus {
        0 => Some(false), // offline (on battery)
        1 => Some(true),  // online (AC plugged in)
        _ => None,        // 255 = unknown
    }
}

/// Spawn a background task that polls AC status every 3 s and updates the
/// shared flag. Supervisor code reads the flag to gate supply.
///
/// The 3-second cadence is a deliberate balance: fast enough that a user
/// unplugging their laptop sees the tray icon flip within ~5 s (one poll
/// interval plus the relay heartbeat round-trip), slow enough that we
/// don't burn wakeups on an idle machine.
pub fn spawn_ac_poller(shared: Arc<AtomicBool>) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(3));
        // Skip the immediate first tick — initial state was set by caller.
        interval.tick().await;
        loop {
            interval.tick().await;
            if let Some(on_ac) = is_on_ac() {
                let previous = shared.swap(on_ac, Ordering::SeqCst);
                if previous != on_ac {
                    if on_ac {
                        info!("AC power restored — resuming supply");
                    } else {
                        warn!("AC power lost — pausing supply until plugged in");
                    }
                }
            }
        }
    });
}

/// Initial AC reading captured synchronously at node startup. The poller
/// (spawn_ac_poller) keeps it up to date from there.
pub fn initial_ac_state() -> bool {
    // `None` means unknown — default to `true` (on AC) so desktops without
    // a battery driver never accidentally self-quarantine.
    is_on_ac().unwrap_or(true)
}

/// Type-level hint used at hazardous-unsafe boundaries — forces us to call
/// a free function instead of accidentally re-implementing the Drop logic.
#[allow(dead_code)]
#[inline(always)]
fn _exec_state_bits() -> EXECUTION_STATE {
    ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED
}

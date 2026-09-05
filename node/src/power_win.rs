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
use windows::Win32::Foundation::FILETIME;
use windows::Win32::System::Power::{
    GetSystemPowerStatus, SetThreadExecutionState, ES_AWAYMODE_REQUIRED, ES_CONTINUOUS,
    ES_SYSTEM_REQUIRED, EXECUTION_STATE, SYSTEM_POWER_STATUS,
};
use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::System::Threading::GetSystemTimes;

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
            let _ =
                SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED);
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

// ---------------------------------------------------------------------------
// Employee-machine throttling (#167)
//
// Two signals, both cheap OS queries, polled every few seconds:
//   1. CPU pressure via GetSystemTimes deltas over a sliding window. When
//      average busy% crosses the configured threshold the node throttles to
//      0, which the gateway scheduler already honors (routing score x
//      throttle/100), so the machine simply stops being picked for work.
//   2. User activity via GetLastInputInfo. In `idle_only` mode the node
//      supplies only after the user has been away for `idle_after_secs`.
//
// Both feed the same throttle flag: 100 = full supply, 0 = paused.
// ---------------------------------------------------------------------------

use std::collections::VecDeque;
use std::sync::atomic::AtomicU32;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};

#[derive(Debug, Clone, Copy)]
pub struct ThrottleConfig {
    pub pause_on_cpu_busy: bool,
    pub cpu_busy_threshold_pct: u32,
    pub cpu_busy_window_secs: u64,
    pub idle_only: bool,
    pub idle_after_secs: u64,
}

fn filetime_to_u64(t: &FILETIME) -> u64 {
    ((t.dwHighDateTime as u64) << 32) | (t.dwLowDateTime as u64)
}

/// (idle_ticks, busy_ticks) since boot. Ticks are 100ns units.
fn cpu_tick_snapshot() -> Option<(u64, u64)> {
    let mut idle = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // Safety: out-params only; GetSystemTimes writes into the three
    // FILETIMEs and reports failure via the return value.
    let ok = unsafe { GetSystemTimes(&mut idle as *mut _, &mut kernel as *mut _, &mut user as *mut _) };
    if !ok.as_bool() {
        return None;
    }
    // Kernel time already includes idle time; subtract to get true busy.
    let idle = filetime_to_u64(&idle);
    let busy = filetime_to_u64(&kernel)
        .saturating_add(filetime_to_u64(&user))
        .saturating_sub(idle);
    Some((idle, busy))
}

/// Seconds since the last keyboard/mouse input. `None` when the OS can't
/// say (e.g. non-interactive session) - callers treat that as "active",
/// which is the conservative choice for employee machines.
pub fn seconds_since_last_input() -> Option<u64> {
    let mut info = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        dwTime: 0,
    };
    // Safety: cbSize is set correctly; GetLastInputInfo only writes dwTime.
    let ok = unsafe { GetLastInputInfo(&mut info as *mut _) };
    if !ok.as_bool() {
        return None;
    }
    // GetTickCount wraps after ~49 days; wrapping_sub keeps deltas sane.
    let now = unsafe { GetTickCount() };
    Some((now.wrapping_sub(info.dwTime) as u64) / 1000)
}

/// Spawn the throttle poller. `shared` holds the throttle level the
/// heartbeat advertises: 100 (full) or 0 (paused). Transitions are logged.
pub fn spawn_throttle_poller(cfg: ThrottleConfig, shared: Arc<AtomicU32>) {
    tokio::spawn(async move {
        const POLL_SECONDS: u64 = 5;
        let mut interval = tokio::time::interval(Duration::from_secs(POLL_SECONDS));
        interval.tick().await; // skip immediate tick

        let mut last: Option<(u64, u64)> = None;
        // (idle_delta, busy_delta) samples inside the sliding window.
        let mut window: VecDeque<(u64, u64, std::time::Instant)> = VecDeque::new();

        loop {
            interval.tick().await;

            let mut reasons: Vec<&'static str> = Vec::new();

            if cfg.pause_on_cpu_busy {
                if let Some((idle, busy)) = cpu_tick_snapshot() {
                    if let Some((prev_idle, prev_busy)) = last {
                        let di = idle.saturating_sub(prev_idle);
                        let db = busy.saturating_sub(prev_busy);
                        window.push_back((di, db, std::time::Instant::now()));
                    }
                    last = Some((idle, busy));
                }
                let cutoff = std::time::Instant::now()
                    .checked_sub(Duration::from_secs(cfg.cpu_busy_window_secs))
                    .unwrap_or_else(std::time::Instant::now);
                while matches!(window.front(), Some((_, _, t)) if *t < cutoff) {
                    window.pop_front();
                }
                let idle_sum: u64 = window.iter().map(|(i, _, _)| *i).sum();
                let busy_sum: u64 = window.iter().map(|(_, b, _)| *b).sum();
                let total = idle_sum.saturating_add(busy_sum);
                // Need a few samples before judging; stay supplying until then.
                if window.len() >= 3 && total > 0 {
                    let busy_pct = (busy_sum as f64 / total as f64) * 100.0;
                    if busy_pct > cfg.cpu_busy_threshold_pct as f64 {
                        reasons.push("cpu-busy");
                    }
                }
            }

            if cfg.idle_only {
                match seconds_since_last_input() {
                    Some(secs) if secs >= cfg.idle_after_secs => {}
                    _ => reasons.push("user-active"),
                }
            }

            let level: u32 = if reasons.is_empty() { 100 } else { 0 };
            let previous = shared.swap(level, Ordering::SeqCst);
            if previous != level {
                if level == 0 {
                    warn!(
                        "Throttling supply to 0 ({}) - host machine takes priority",
                        reasons.join("+")
                    );
                } else {
                    info!("Throttle cleared - resuming full supply");
                }
            }
        }
    });
}

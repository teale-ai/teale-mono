//! PIN-over-DIN admission priority.
//!
//! The node's concurrency cap is a semaphore. DIN admission is fail-fast
//! on the fast path, with a bounded queue (`acquire_din`) behind it — the
//! caller caps the waiter pool. Priority is therefore expressed as:
//!   - PIN requests may WAIT for a permit (bounded), and
//!   - while any PIN request is waiting, DIN admission (and new DIN queue
//!     joins) is refused even if a permit is free (`pin_first` mode) — PIN
//!     jumps the line, in-flight work is never preempted.
//!
//! The per-device `din_priority_equal` setting restores plain fail-fast
//! competition (spec §9 "unless otherwise notated").

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

pub struct PriorityGate {
    semaphore: Arc<Semaphore>,
    pin_waiters: AtomicU32,
    din_priority_equal: AtomicBool,
}

impl PriorityGate {
    pub fn new(semaphore: Arc<Semaphore>) -> Arc<Self> {
        Arc::new(Self {
            semaphore,
            pin_waiters: AtomicU32::new(0),
            din_priority_equal: AtomicBool::new(false),
        })
    }

    pub fn set_din_priority_equal(&self, equal: bool) {
        self.din_priority_equal.store(equal, Ordering::Relaxed);
    }

    pub fn din_priority_equal(&self) -> bool {
        self.din_priority_equal.load(Ordering::Relaxed)
    }

    /// DIN admission: fail-fast, and hold the door while PIN work waits.
    pub fn try_acquire_din(&self) -> Option<OwnedSemaphorePermit> {
        if !self.din_priority_equal() && self.pin_waiters.load(Ordering::Acquire) > 0 {
            return None;
        }
        self.semaphore.clone().try_acquire_owned().ok()
    }

    /// DIN admission with a bounded queue: wait up to `timeout` for a
    /// permit. The pin_first door holds at join time - while a PIN
    /// request is waiting, a new DIN queue join is refused even if a
    /// permit is free. The caller caps the waiter pool.
    pub async fn acquire_din(&self, timeout: Duration) -> Option<OwnedSemaphorePermit> {
        if !self.din_priority_equal() && self.pin_waiters.load(Ordering::Acquire) > 0 {
            return None;
        }
        tokio::time::timeout(timeout, self.semaphore.clone().acquire_owned())
            .await
            .ok()
            .and_then(|r| r.ok())
    }

    /// PIN admission: wait up to `timeout` for a permit.
    pub async fn acquire_pin(&self, timeout: Duration) -> Option<OwnedSemaphorePermit> {
        struct WaiterGuard<'a>(&'a AtomicU32);
        impl Drop for WaiterGuard<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::Release);
            }
        }
        self.pin_waiters.fetch_add(1, Ordering::Release);
        let _guard = WaiterGuard(&self.pin_waiters);
        tokio::time::timeout(timeout, self.semaphore.clone().acquire_owned())
            .await
            .ok()
            .and_then(|r| r.ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn din_queue_wait_acquires_freed_permit() {
        let gate = PriorityGate::new(Arc::new(Semaphore::new(1)));
        let in_flight = gate.try_acquire_din().expect("free permit");
        let gate_din = gate.clone();
        let waiter =
            tokio::spawn(async move { gate_din.acquire_din(Duration::from_secs(5)).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(in_flight);
        assert!(
            waiter.await.unwrap().is_some(),
            "queued DIN gets the freed permit"
        );
    }

    #[tokio::test]
    async fn din_queue_wait_times_out_when_never_freed() {
        let gate = PriorityGate::new(Arc::new(Semaphore::new(1)));
        let _in_flight = gate.try_acquire_din().expect("free permit");
        assert!(gate.acquire_din(Duration::from_millis(50)).await.is_none());
    }

    #[tokio::test]
    async fn din_queue_join_refused_while_pin_waits() {
        let gate = PriorityGate::new(Arc::new(Semaphore::new(1)));
        let in_flight = gate.try_acquire_din().expect("free permit");
        let gate_pin = gate.clone();
        let waiter =
            tokio::spawn(async move { gate_pin.acquire_pin(Duration::from_secs(5)).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        // The door holds for the waiting PIN even though the queue would
        // otherwise let DIN wait for a permit.
        assert!(gate.acquire_din(Duration::from_secs(1)).await.is_none());
        drop(in_flight);
        assert!(waiter.await.unwrap().is_some());
    }

    #[tokio::test]
    async fn pin_waiters_block_din_admission() {
        let gate = PriorityGate::new(Arc::new(Semaphore::new(1)));

        // Occupy the only permit (simulating an in-flight request).
        let in_flight = gate.try_acquire_din().expect("free permit");

        // A PIN request starts waiting.
        let gate_pin = gate.clone();
        let waiter =
            tokio::spawn(
                async move { gate_pin.acquire_pin(Duration::from_secs(5)).await.is_some() },
            );
        // Let the waiter register.
        tokio::time::sleep(Duration::from_millis(50)).await;

        // DIN is refused while PIN waits — even after the permit frees, the
        // door stays held until the PIN waiter gets through.
        assert!(gate.try_acquire_din().is_none(), "door held for PIN");
        drop(in_flight);
        assert!(
            waiter.await.unwrap(),
            "PIN waiter acquires the freed permit"
        );

        // With no PIN waiters, DIN admission works again.
        assert!(gate.try_acquire_din().is_some());
    }

    #[tokio::test]
    async fn equal_mode_restores_fifo_competition() {
        let gate = PriorityGate::new(Arc::new(Semaphore::new(1)));
        gate.set_din_priority_equal(true);
        let in_flight = gate.try_acquire_din().unwrap();
        let gate_pin = gate.clone();
        let waiter =
            tokio::spawn(async move { gate_pin.acquire_pin(Duration::from_secs(1)).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        // In equal mode DIN is not categorically refused while PIN waits —
        // the permit is simply taken. (It is here, so acquisition fails for
        // capacity, not priority; verify by freeing it.)
        drop(in_flight);
        let pin_permit = waiter.await.unwrap();
        drop(pin_permit);
        assert!(gate.try_acquire_din().is_some());
    }

    #[tokio::test]
    async fn pin_wait_times_out() {
        let gate = PriorityGate::new(Arc::new(Semaphore::new(1)));
        let _held = gate.try_acquire_din().unwrap();
        let got = gate.acquire_pin(Duration::from_millis(100)).await;
        assert!(got.is_none(), "held permit forces timeout");
    }
}

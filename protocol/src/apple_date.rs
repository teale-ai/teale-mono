//! Apple reference-date encoding: seconds since 2001-01-01T00:00:00Z as f64.
//! Matches Swift's `.deferredToDate` JSON strategy — the wire format of
//! `registeredAt`, `lastSeen`, and all `timestamp` fields.

pub const APPLE_REFERENCE_OFFSET: f64 = 978_307_200.0;

/// Seconds since Apple reference date (2001-01-01), as f64.
pub fn now_reference_seconds() -> f64 {
    let unix_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    unix_secs - APPLE_REFERENCE_OFFSET
}

pub fn unix_to_reference(unix_secs: f64) -> f64 {
    unix_secs - APPLE_REFERENCE_OFFSET
}

pub fn reference_to_unix(ref_secs: f64) -> f64 {
    ref_secs + APPLE_REFERENCE_OFFSET
}

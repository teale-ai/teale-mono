//! Shared application state available to all handlers.

use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::broadcast;

use crate::auth::TokenTable;
use crate::catalog::CatalogModel;
use crate::config::Config;
use crate::db::DbPool;
use crate::handlers::groups::GroupMessage;
use crate::model_metrics::ModelMetricsTracker;
use crate::providers::ProvidersHandle;
use crate::registry::Registry;
use crate::relay_client::RelayHandle;
use crate::scheduler::Scheduler;

/// Sliding-window rate limiter for PIN join knocks: a device may submit at
/// most `MAX_PER_WINDOW` join requests per hour, valid code or not. Keyed by
/// device id; the join endpoint's response never reveals whether the code
/// matched, so the limiter is the only brute-force defense.
#[derive(Debug, Clone, Default)]
pub struct PinJoinLimiter {
    inner: Arc<parking_lot::Mutex<std::collections::HashMap<String, Vec<i64>>>>,
}

impl PinJoinLimiter {
    pub const MAX_PER_WINDOW: usize = 5;
    pub const WINDOW_SECONDS: i64 = 3600;

    /// Record an attempt; returns false when the caller is over the limit.
    pub fn allow(&self, key: &str, now_unix: i64) -> bool {
        let mut map = self.inner.lock();
        let attempts = map.entry(key.to_string()).or_default();
        attempts.retain(|t| now_unix - *t < Self::WINDOW_SECONDS);
        if attempts.len() >= Self::MAX_PER_WINDOW {
            return false;
        }
        attempts.push(now_unix);
        true
    }
}

/// Per-client-IP sliding-window rate limiter for /v1/auth/device/challenge.
/// DeviceIDs are self-generated, so the welcome grant would otherwise be
/// farmable without bound: each new device needs a fresh challenge, and the
/// challenge is where the per-IP ceiling binds (10/hour = at most $1/hour of
/// grants per source IP at the $0.10 welcome grant). Keyed by Fly's
/// `fly-client-ip` header (proxy-set, not client-spoofable); requests
/// without it share one "unknown" bucket - fail-closed by construction.
#[derive(Debug, Clone, Default)]
pub struct ChallengeLimiter {
    inner: Arc<parking_lot::Mutex<std::collections::HashMap<String, Vec<i64>>>>,
}

impl ChallengeLimiter {
    pub const MAX_PER_WINDOW: usize = 10;
    pub const WINDOW_SECONDS: i64 = 3600;

    /// Record an attempt; returns false when the caller is over the limit.
    pub fn allow(&self, key: &str, now_unix: i64) -> bool {
        let mut map = self.inner.lock();
        let attempts = map.entry(key.to_string()).or_default();
        attempts.retain(|t| now_unix - *t < Self::WINDOW_SECONDS);
        if attempts.len() >= Self::MAX_PER_WINDOW {
            return false;
        }
        attempts.push(now_unix);
        true
    }

}

/// Allowlist for minting share keys. Loaded from `GATEWAY_SHARE_KEY_ISSUERS`
/// (comma-separated 64-char hex device IDs). Empty set ⇒ mint disabled —
/// fail-closed default so a deploy without the secret can't be abused.
#[derive(Debug, Clone, Default)]
pub struct ShareKeyIssuers(Arc<HashSet<String>>);

impl ShareKeyIssuers {
    pub fn from_env(var: &str) -> Self {
        let raw = std::env::var(var).unwrap_or_default();
        let set: HashSet<String> = raw
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if set.is_empty() {
            tracing::warn!(
                "{} is empty — share-key mint endpoint is DISABLED until set",
                var
            );
        } else {
            tracing::info!(
                "{} configured: {} issuer device(s) allowed to mint share keys",
                var,
                set.len()
            );
        }
        Self(Arc::new(set))
    }

    pub fn is_allowed(&self, device_id: &str) -> bool {
        self.0.contains(device_id)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_key_issuers_parses_comma_list() {
        std::env::set_var("TEST_SKI_OK", "  dev_a ,dev_b,  , dev_c ");
        let s = ShareKeyIssuers::from_env("TEST_SKI_OK");
        assert!(s.is_allowed("dev_a"));
        assert!(s.is_allowed("dev_b"));
        assert!(s.is_allowed("dev_c"));
        assert!(!s.is_allowed("dev_d"));
        assert!(!s.is_empty());
        std::env::remove_var("TEST_SKI_OK");
    }

    #[test]
    fn challenge_limiter_blocks_over_limit_and_slides() {
        let l = ChallengeLimiter::default();
        let t0 = 1_000_000i64;
        for _ in 0..ChallengeLimiter::MAX_PER_WINDOW {
            assert!(l.allow("1.2.3.4", t0));
        }
        assert!(!l.allow("1.2.3.4", t0), "11th challenge in-window must block");
        assert!(l.allow("5.6.7.8", t0), "limit is per-IP");
        // Window slides: an hour later the oldest attempt has expired.
        assert!(l.allow("1.2.3.4", t0 + ChallengeLimiter::WINDOW_SECONDS));
    }

    #[test]
    fn share_key_issuers_empty_when_var_unset() {
        std::env::remove_var("TEST_SKI_UNSET");
        let s = ShareKeyIssuers::from_env("TEST_SKI_UNSET");
        assert!(s.is_empty());
        assert!(!s.is_allowed("anything"));
    }
}

#[derive(Clone)]
pub struct AppState {
    pub config: Config,
    pub tokens: TokenTable,
    pub registry: Arc<Registry>,
    pub scheduler: Arc<Scheduler>,
    pub relay: RelayHandle,
    pub catalog: Arc<Vec<CatalogModel>>,
    /// SQLite-backed ledger + groups DB. `None` only in tests / pre-init.
    pub db: Option<DbPool>,
    /// Broadcast channel of group messages for SSE live-stream.
    pub group_tx: broadcast::Sender<GroupMessage>,
    /// Per-model rolling TTFT/TPS stats, surfaced on `/v1/models`.
    pub model_metrics: Arc<ModelMetricsTracker>,
    /// Device IDs allowed to mint share keys. Fail-closed when empty.
    pub share_key_issuers: ShareKeyIssuers,
    /// Centralized 3rd-party provider marketplace. Loaded at startup from
    /// the `providers` / `provider_models` tables; refreshed on admin mutation.
    pub providers: ProvidersHandle,
    /// Gateway Ed25519 identity, used to sign PIN netmaps. `None` only in
    /// tests that don't exercise netmap endpoints.
    pub identity: Option<Arc<crate::identity::GatewayIdentity>>,
    /// Process start, for the post-restart registry warmup window (see
    /// ReliabilityConfig::registry_warmup_seconds).
    pub started_at: std::time::Instant,
    /// Join-knock rate limiting for /v1/pins/join.
    pub pin_join_limiter: PinJoinLimiter,
    /// Per-IP rate limiting for /v1/auth/device/challenge (welcome-grant
    /// farming defense).
    pub challenge_limiter: ChallengeLimiter,
}

//! Shared application state available to all handlers.

use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::broadcast;

use crate::auth::TokenTable;
use crate::catalog::CatalogModel;
use crate::config::Config;
use crate::db::DbPool;
use crate::handlers::groups::GroupMessage;
use crate::registry::Registry;
use crate::relay_client::RelayHandle;
use crate::scheduler::Scheduler;

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
    /// Device IDs allowed to mint share keys. Fail-closed when empty.
    pub share_key_issuers: ShareKeyIssuers,
}

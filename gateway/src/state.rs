//! Shared application state available to all handlers.

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
}

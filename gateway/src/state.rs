//! Shared application state available to all handlers.

use std::sync::Arc;

use crate::auth::TokenTable;
use crate::catalog::CatalogModel;
use crate::config::Config;
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
}

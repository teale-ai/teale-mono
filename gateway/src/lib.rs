//! Re-exports so integration tests in gateway/tests/ can reach
//! internal modules. The binary entry-point is still main.rs.

pub mod auth;
pub mod catalog;
pub mod config;
pub mod db;
pub mod error;
pub mod handlers;
pub mod identity;
pub mod ledger;
pub mod metrics;
pub mod model_metrics;
pub mod probe;
pub mod providers;
pub mod registry;
pub mod relay_client;
pub mod router;
pub mod scheduler;
pub mod state;

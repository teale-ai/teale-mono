//! teale-gateway: OpenAI-compatible HTTP gateway that fronts the TealeNet
//! relay and dispatches inference to Mac/Android/HarmonyOS supply nodes.

use std::sync::Arc;

use axum::{
    middleware,
    routing::{get, post},
    Router,
};
use clap::Parser;
use tokio::sync::broadcast;
use tower_http::trace::TraceLayer;
use tracing::{info, Level};
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use teale_gateway::auth::TokenTable;
use teale_gateway::config::Config;
use teale_gateway::db;
use teale_gateway::identity::GatewayIdentity;
use teale_gateway::ledger;
use teale_gateway::registry::Registry;
use teale_gateway::scheduler::Scheduler;
use teale_gateway::state::{AppState, ShareKeyIssuers};
use teale_gateway::{auth, catalog, handlers, metrics, relay_client};

#[derive(Parser)]
#[command(
    name = "teale-gateway",
    about = "OpenAI-compatible gateway for TealeNet"
)]
struct Args {
    #[arg(short, long, default_value = "gateway.toml")]
    config: String,

    #[arg(short, long)]
    models_yaml: Option<String>,

    /// Path to the SQLite ledger DB. May also be overridden via GATEWAY_DB_PATH env var.
    #[arg(long, default_value = "/data/ledger.db")]
    db_path: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(fmt::layer().with_target(false))
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,teale_gateway=debug")),
        )
        .init();

    let args = Args::parse();
    let mut config = Config::load(&args.config)?;
    if let Some(p) = args.models_yaml {
        config.models_yaml = p;
    }
    let db_path = std::env::var("GATEWAY_DB_PATH").unwrap_or(args.db_path);

    metrics::init();

    info!("teale-gateway v{}", env!("CARGO_PKG_VERSION"));
    info!("Config: bind={}, relay={}", config.bind, config.relay.url);
    info!("Ledger DB: {}", db_path);

    let identity = Arc::new(GatewayIdentity::load_or_create(&config.identity_path)?);
    info!("Gateway nodeID: {}", identity.node_id());

    let catalog_models = catalog::load(&config.models_yaml)
        .map_err(|e| anyhow::anyhow!("load catalog {}: {}", config.models_yaml, e))?;
    info!(
        "Loaded {} model(s) from {}",
        catalog_models.len(),
        config.models_yaml
    );

    // Open ledger DB. If the path is unwritable, fall back to a tempfile so
    // we still boot (Fly machines without an attached volume).
    let pool = match db::open(&db_path) {
        Ok(p) => Some(p),
        Err(e) => {
            tracing::warn!(
                "could not open ledger DB at {} ({}); falling back to in-memory",
                db_path,
                e
            );
            db::open_in_memory().ok()
        }
    };

    let registry = Registry::new(config.reliability.clone());
    let scheduler = Arc::new(Scheduler::new(config.scheduler.clone()));
    let relay = relay_client::spawn(&config, identity.clone(), registry.clone()).await?;

    let tokens = TokenTable::from_env("GATEWAY_TOKENS");
    let share_key_issuers = ShareKeyIssuers::from_env("GATEWAY_SHARE_KEY_ISSUERS");

    let (group_tx, _group_rx) = broadcast::channel(256);

    let state = AppState {
        config: config.clone(),
        tokens: tokens.clone(),
        registry: registry.clone(),
        scheduler,
        relay,
        catalog: Arc::new(catalog_models),
        db: pool.clone(),
        group_tx,
        model_metrics: Arc::new(teale_gateway::model_metrics::ModelMetricsTracker::new()),
        share_key_issuers,
    };

    // Spawn the Teale Credit availability drip loop.
    if let Some(pool_for_drip) = pool.clone() {
        let registry_for_drip = registry.clone();
        ledger::spawn_drip_loop(pool_for_drip, move || {
            registry_for_drip
                .snapshot_devices()
                .into_iter()
                .filter(|d| !d.is_quarantined() && d.capabilities.is_available)
                .map(|d| d.node_id)
                .collect()
        });
        tracing::info!(
            "spawned availability drip loop ({}s)",
            ledger::DRIP_INTERVAL_SECS
        );
    }

    // Protected routes — require any valid bearer (static or device).
    let protected = Router::new()
        .route(
            "/v1/chat/completions",
            post(handlers::chat::chat_completions),
        )
        .route("/v1/completions", post(handlers::completions::completions))
        .route("/v1/models", get(handlers::models::list_models))
        .route("/v1/network", get(handlers::network::network))
        .route("/v1/wallet/balance", get(handlers::wallet::balance))
        .route(
            "/v1/wallet/transactions",
            get(handlers::wallet::transactions),
        )
        .route("/v1/groups", post(handlers::groups::create_group))
        .route("/v1/groups/mine", get(handlers::groups::list_mine))
        .route("/v1/groups/:id/members", post(handlers::groups::add_member))
        .route(
            "/v1/groups/:id/messages",
            post(handlers::groups::post_message).get(handlers::groups::list_messages),
        )
        .route(
            "/v1/groups/:id/memory",
            post(handlers::groups::remember).get(handlers::groups::recall),
        )
        .route(
            "/v1/auth/device/username",
            axum::routing::patch(handlers::auth::set_username),
        )
        .route(
            "/v1/auth/keys/share",
            post(handlers::share_keys::mint).get(handlers::share_keys::list),
        )
        .route(
            "/v1/auth/keys/share/:key_id",
            axum::routing::delete(handlers::share_keys::revoke),
        )
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_bearer,
        ));

    // Public routes — no auth. SSE stream does bearer check in-handler.
    let public = Router::new()
        .route("/health", get(handlers::health::health))
        .route("/metrics", get(handlers::metrics::metrics))
        .route("/privacy", get(handlers::privacy::privacy))
        .route("/favicon.ico", get(handlers::favicon::favicon_ico))
        .route("/favicon.png", get(handlers::favicon::favicon_png))
        .route("/favicon.svg", get(handlers::favicon::favicon_svg))
        .route("/v1/auth/device/challenge", post(handlers::auth::challenge))
        .route("/v1/auth/device/exchange", post(handlers::auth::exchange))
        .route(
            "/v1/auth/keys/share/preview/:token",
            get(handlers::share_keys::preview),
        )
        .route("/try/:token", get(handlers::try_page::try_page))
        .route(
            "/v1/groups/:id/stream",
            get(handlers::groups::stream_messages),
        );

    let app = Router::new()
        .merge(protected)
        .merge(public)
        .with_state(state)
        .layer(
            TraceLayer::new_for_http().make_span_with(|req: &axum::http::Request<_>| {
                tracing::span!(
                    Level::INFO,
                    "http",
                    method = %req.method(),
                    uri = %req.uri(),
                )
            }),
        );

    let listener = tokio::net::TcpListener::bind(&config.bind).await?;
    info!("listening on {}", config.bind);
    axum::serve(listener, app.into_make_service()).await?;
    Ok(())
}

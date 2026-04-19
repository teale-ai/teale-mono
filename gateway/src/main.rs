//! teale-gateway: OpenAI-compatible HTTP gateway that fronts the TealeNet
//! relay and dispatches inference to Mac supply nodes.

use std::sync::Arc;

use axum::{
    middleware,
    routing::{get, post},
    Router,
};
use clap::Parser;
use tower_http::trace::TraceLayer;
use tracing::{info, Level};
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use teale_gateway::auth::TokenTable;
use teale_gateway::config::Config;
use teale_gateway::identity::GatewayIdentity;
use teale_gateway::registry::Registry;
use teale_gateway::scheduler::Scheduler;
use teale_gateway::state::AppState;
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

    metrics::init();

    info!("teale-gateway v{}", env!("CARGO_PKG_VERSION"));
    info!("Config: bind={}, relay={}", config.bind, config.relay.url);

    let identity = Arc::new(GatewayIdentity::load_or_create(&config.identity_path)?);
    info!("Gateway nodeID: {}", identity.node_id());

    let catalog_models = catalog::load(&config.models_yaml)
        .map_err(|e| anyhow::anyhow!("load catalog {}: {}", config.models_yaml, e))?;
    info!(
        "Loaded {} model(s) from {}",
        catalog_models.len(),
        config.models_yaml
    );

    let registry = Registry::new(config.reliability.clone());
    let scheduler = Arc::new(Scheduler::new(config.scheduler.clone()));
    let relay = relay_client::spawn(&config, identity.clone(), registry.clone()).await?;

    let tokens = TokenTable::from_env("GATEWAY_TOKENS");

    let state = AppState {
        config: config.clone(),
        tokens: tokens.clone(),
        registry,
        scheduler,
        relay,
        catalog: Arc::new(catalog_models),
    };

    let protected = Router::new()
        .route(
            "/v1/chat/completions",
            post(handlers::chat::chat_completions),
        )
        .route("/v1/completions", post(handlers::completions::completions))
        .route("/v1/models", get(handlers::models::list_models))
        .layer(middleware::from_fn_with_state(
            tokens.clone(),
            auth::require_bearer,
        ));

    let public = Router::new()
        .route("/health", get(handlers::health::health))
        .route("/metrics", get(handlers::metrics::metrics))
        .route("/privacy", get(handlers::privacy::privacy));

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

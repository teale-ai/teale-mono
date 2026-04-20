use axum::{
    extract::State,
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use teale_protocol::openai::ModelsResponse;

use crate::catalog::is_large;
use crate::state::AppState;

const CATALOG_HTML: &str = include_str!("models.html");

pub async fn list_models(State(state): State<AppState>, headers: HeaderMap) -> Response {
    // Content negotiation: browsers (Accept: text/html) get the styled catalog
    // page; curl/SDKs (Accept: */* or application/json) keep the raw JSON.
    let wants_html = headers
        .get(header::ACCEPT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.contains("text/html"))
        .unwrap_or(false);

    if wants_html {
        let mut h = HeaderMap::new();
        h.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/html; charset=utf-8"),
        );
        h.insert(
            header::CACHE_CONTROL,
            HeaderValue::from_static("public, max-age=60"),
        );
        h.insert(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static(
                "default-src 'self'; style-src 'self' 'unsafe-inline'; \
                 script-src 'self' 'unsafe-inline'; img-src 'self' data:",
            ),
        );
        return (h, CATALOG_HTML).into_response();
    }

    let floor = &state.config.scheduler.per_model_floor;
    let entries: Vec<_> = state
        .catalog
        .iter()
        .filter(|m| {
            // Virtual meta-models (e.g. teale/auto) are always advertised;
            // resolution happens at request time against concrete supply.
            if m.is_virtual {
                return true;
            }
            // Enforce per-model fleet floor: hide models we can't serve healthily.
            let min = if is_large(m.params_b) {
                floor.large
            } else {
                floor.small
            };
            state.registry.loaded_count(&m.id) >= min
        })
        .map(|m| m.to_entry_with_metrics(state.model_metrics.snapshot(&m.id)))
        .collect();

    Json(ModelsResponse {
        object: "list".to_string(),
        data: entries,
    })
    .into_response()
}

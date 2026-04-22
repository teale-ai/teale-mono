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
const HIDDEN_MODEL_IDS: &[&str] = &["moonshotai/kimi-k2"];

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
        // Without `Vary: Accept`, the browser caches the HTML response under
        // `/v1/models` and reuses it for the page's `Accept: application/json`
        // fetch, which then hits `res.json()` and throws
        // `Unexpected token '<', "<!doctype "... is not valid JSON`.
        h.insert(header::VARY, HeaderValue::from_static("Accept"));
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
    let connected_device_count = state.registry.device_count() as u32;
    let entries: Vec<_> = state
        .catalog
        .iter()
        .filter(|m| !HIDDEN_MODEL_IDS.contains(&m.id.as_str()))
        .filter(|m| {
            // Enforce per-model fleet floor: hide models we can't serve healthily.
            let min = if is_large(m.params_b) {
                floor.large
            } else {
                floor.small
            };
            state.registry.loaded_count(&m.id) >= min
        })
        .map(|m| {
            let loaded_device_count = state.registry.loaded_count(&m.id);
            m.to_entry_with_live_state(state.model_metrics.snapshot(&m.id), loaded_device_count)
        })
        .collect();

    let mut h = HeaderMap::new();
    h.insert(header::VARY, HeaderValue::from_static("Accept"));
    (
        h,
        Json(ModelsResponse {
            object: "list".to_string(),
            connected_device_count: Some(connected_device_count),
            data: entries,
        }),
    )
        .into_response()
}

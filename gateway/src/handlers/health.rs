use axum::{extract::State, Json};
use serde_json::{json, Value};

use crate::state::AppState;

pub async fn health(State(state): State<AppState>) -> Json<Value> {
    let devices = state.registry.device_count();
    Json(json!({
        "status": if devices > 0 { "ok" } else { "degraded" },
        "devices_connected": devices,
        "gateway_node_id": state.relay.node_id(),
    }))
}

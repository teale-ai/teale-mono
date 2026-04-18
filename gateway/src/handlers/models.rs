use axum::{extract::State, Json};
use teale_protocol::openai::ModelsResponse;

use crate::catalog::is_large;
use crate::state::AppState;

pub async fn list_models(State(state): State<AppState>) -> Json<ModelsResponse> {
    let floor = &state.config.scheduler.per_model_floor;
    let entries: Vec<_> = state
        .catalog
        .iter()
        .filter(|m| {
            // Enforce per-model fleet floor: hide models we can't serve healthily.
            let min = if is_large(m.params_b) { floor.large } else { floor.small };
            state.registry.loaded_count(&m.id) >= min
        })
        .map(|m| m.to_entry())
        .collect();

    Json(ModelsResponse {
        object: "list".to_string(),
        data: entries,
    })
}

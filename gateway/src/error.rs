use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use thiserror::Error;

/// Errors surfaced to the HTTP layer. Mapped to OpenAI-style error bodies.
#[derive(Debug, Error)]
pub enum GatewayError {
    #[error("unauthorized: {0}")]
    Unauthorized(String),

    #[error("bad request: {0}")]
    BadRequest(String),

    #[error("{0}")]
    NotFound(String),

    #[error("forbidden: {0}")]
    Forbidden(String),

    #[error("share-key budget exhausted")]
    BudgetExhausted,

    #[error("insufficient credits: balance {balance}, need {required}")]
    InsufficientCredits { balance: i64, required: i64 },

    #[error("model not found: {0}")]
    ModelNotFound(String),

    #[error("no eligible device for model {0}")]
    NoEligibleDevice(String),

    #[error("upstream error: {0}")]
    Upstream(String),

    #[error("all upstreams failed: {0}")]
    AllUpstreamsFailed(String),

    #[error("timeout waiting for upstream")]
    UpstreamTimeout,

    #[error("relay unavailable: {0}")]
    RelayUnavailable(String),

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl GatewayError {
    pub fn status(&self) -> StatusCode {
        match self {
            Self::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::Forbidden(_) => StatusCode::FORBIDDEN,
            Self::BudgetExhausted => StatusCode::PAYMENT_REQUIRED,
            Self::InsufficientCredits { .. } => StatusCode::PAYMENT_REQUIRED,
            Self::ModelNotFound(_) => StatusCode::NOT_FOUND,
            Self::NoEligibleDevice(_) => StatusCode::SERVICE_UNAVAILABLE,
            Self::Upstream(_) => StatusCode::BAD_GATEWAY,
            Self::AllUpstreamsFailed(_) => StatusCode::BAD_GATEWAY,
            Self::UpstreamTimeout => StatusCode::GATEWAY_TIMEOUT,
            Self::RelayUnavailable(_) => StatusCode::SERVICE_UNAVAILABLE,
            Self::Other(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::Unauthorized(_) => "unauthorized",
            Self::BadRequest(_) => "invalid_request",
            Self::NotFound(_) => "not_found",
            Self::Forbidden(_) => "forbidden",
            Self::BudgetExhausted => "budget_exhausted",
            Self::InsufficientCredits { .. } => "insufficient_credits",
            Self::ModelNotFound(_) => "model_not_found",
            Self::NoEligibleDevice(_) => "model_unavailable",
            Self::Upstream(_) => "upstream_error",
            Self::AllUpstreamsFailed(_) => "upstream_failed",
            Self::UpstreamTimeout => "timeout",
            Self::RelayUnavailable(_) => "relay_unavailable",
            Self::Other(_) => "internal_error",
        }
    }
}

impl IntoResponse for GatewayError {
    fn into_response(self) -> Response {
        let mut err = json!({
            "message": self.to_string(),
            "type": self.code(),
            "code": self.code(),
        });
        if let Self::InsufficientCredits { balance, required } = &self {
            err["balance"] = json!(*balance);
            err["required"] = json!(*required);
        }
        let body = Json(json!({ "error": err }));
        (self.status(), body).into_response()
    }
}

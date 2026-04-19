//! GET /privacy — public-facing privacy policy.
//!
//! Served as plain-text from the gateway itself so we have a durable URL
//! (`https://gateway.teale.com/privacy`) to paste into OpenRouter's provider
//! application. Self-hosting it here sidesteps the docs.teale.com rollout.

use axum::{http::header, response::IntoResponse};

const POLICY: &str = include_str!("privacy.txt");

pub async fn privacy() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        POLICY,
    )
}

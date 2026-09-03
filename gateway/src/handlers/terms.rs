//! GET /terms — public-facing terms of service.
//!
//! Served as plain-text from the gateway itself so we have a durable URL
//! (`https://gateway.teale.com/terms`) to paste into OpenRouter's provider
//! application. Mirrors the /privacy handler.

use axum::{http::header, response::IntoResponse};

const TERMS: &str = include_str!("terms.txt");

pub async fn terms() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        TERMS,
    )
}

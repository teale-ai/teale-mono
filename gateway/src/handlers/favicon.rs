//! GET /favicon.ico, /favicon.png — embedded site icon.
//!
//! Browsers hit /favicon.ico automatically for any page, so serving the same
//! PNG at both paths keeps 404s out of the access log.

use axum::{
    http::{header, HeaderMap, HeaderValue},
    response::IntoResponse,
};

const ICON: &[u8] = include_bytes!("favicon.png");

pub async fn favicon() -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("image/png"));
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400, immutable"),
    );
    (headers, ICON)
}

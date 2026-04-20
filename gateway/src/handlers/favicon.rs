//! Favicon endpoints.
//!
//! A minimal outline-only mark: head + brain strokes in teal on a
//! transparent background. SVG is the source of truth; PNG is
//! rasterized via resvg so iOS `apple-touch-icon` has a fallback.
//! Both baked into the binary via `include_bytes!`.

use axum::{
    http::{header, HeaderMap, HeaderValue},
    response::IntoResponse,
};

const SVG: &[u8] = include_bytes!("favicon.svg");
const PNG: &[u8] = include_bytes!("favicon.png");

fn headers(content_type: &'static str) -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    h.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400, immutable"),
    );
    h
}

/// GET /favicon.svg — vector, preferred by modern browsers.
pub async fn favicon_svg() -> impl IntoResponse {
    (headers("image/svg+xml"), SVG)
}

/// GET /favicon.png — 1024×1024 rasterized fallback.
pub async fn favicon_png() -> impl IntoResponse {
    (headers("image/png"), PNG)
}

/// GET /favicon.ico — the browser's implicit probe. Returns the PNG body;
/// modern browsers accept it under the .ico path without real ICO encoding.
pub async fn favicon_ico() -> impl IntoResponse {
    (headers("image/png"), PNG)
}

//! Favicon endpoints.
//!
//! Canonical assets live in teale-www/amsterdam (SVG source + 512×512 PNG).
//! We serve both so modern browsers get the crisp vector and the
//! implicit /favicon.ico probe still returns something usable.
//!
//! Brand colors baked into the SVG: #0f172a (slate-900) bg, #14b8a6
//! (teal-light) stroke — matches the rest of the teale network sites.

use axum::{
    http::{header, HeaderMap, HeaderValue},
    response::IntoResponse,
};

const SVG: &[u8] = include_bytes!("favicon.svg");
const PNG: &[u8] = include_bytes!("favicon.png");

fn cache_headers(content_type: &'static str) -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    h.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400, immutable"),
    );
    h
}

/// GET /favicon.svg — vector favicon, preferred by modern browsers.
pub async fn favicon_svg() -> impl IntoResponse {
    (cache_headers("image/svg+xml"), SVG)
}

/// GET /favicon.png — raster fallback.
pub async fn favicon_png() -> impl IntoResponse {
    (cache_headers("image/png"), PNG)
}

/// GET /favicon.ico — browsers' implicit probe. We return the PNG here
/// because real ICO encoding isn't worth the dep; nearly all modern
/// browsers accept a PNG body under the ico path.
pub async fn favicon_ico() -> impl IntoResponse {
    (cache_headers("image/png"), PNG)
}

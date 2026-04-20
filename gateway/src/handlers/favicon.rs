//! Favicon endpoints.
//!
//! Uses the canonical Mac-app icon (the one that ships in the Xcode
//! app bundle — `mac-app/Sources/TealeCompanion/.../AppIcon.appiconset/
//! icon_1024.png`) so every surface the user touches has the same
//! brand mark. Baked into the binary via `include_bytes!`.

use axum::{
    http::{header, HeaderMap, HeaderValue},
    response::IntoResponse,
};

const PNG: &[u8] = include_bytes!("favicon.png");

fn png_headers() -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_static("image/png"));
    h.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400, immutable"),
    );
    h
}

/// GET /favicon.png
pub async fn favicon_png() -> impl IntoResponse {
    (png_headers(), PNG)
}

/// GET /favicon.ico — browsers' implicit probe. We return the PNG here
/// because real ICO encoding isn't worth the dep; modern browsers
/// accept a PNG body under the .ico path.
pub async fn favicon_ico() -> impl IntoResponse {
    (png_headers(), PNG)
}

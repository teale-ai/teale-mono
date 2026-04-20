//! GET /try/:token — terminal-styled landing page for a share key.
//!
//! The page is fully static; it reads the token from `window.location.pathname`
//! and fetches preview data client-side from `/v1/auth/keys/share/preview/:token`.
//! Rendering user-controlled fields uses `textContent` only (never `innerHTML`),
//! so label strings can't carry markup.

use axum::{
    extract::Path,
    http::{header, HeaderMap, HeaderValue},
    response::IntoResponse,
};

const PAGE: &str = include_str!("try.html");

pub async fn try_page(Path(_token): Path<String>) -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    // The HTML is the same for every token; JSON lookup is uncached.
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=300"),
    );
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; style-src 'self' 'unsafe-inline'; \
             script-src 'self' 'unsafe-inline'; img-src 'self' data:",
        ),
    );
    (headers, PAGE)
}

//! Loopback HTTP client for the local Teale daemon - the mac desktop app
//! (port 11435) or the Rust supply node (control port, default 11437).
//! Both expose the same /v1/app-ish contract; flavor detection picks the
//! few routes that differ.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flavor {
    /// macOS desktop app (Teale.app).
    Mac,
    /// Rust teale-node supply daemon.
    Node,
}

impl Flavor {
    pub fn label(self) -> &'static str {
        match self {
            Flavor::Mac => "mac app",
            Flavor::Node => "teale-node",
        }
    }
}

pub struct LocalApi {
    pub base: String,
    client: reqwest::Client,
    pub json: bool,
    pub flavor: Flavor,
}

impl LocalApi {
    /// Find the running daemon: explicit --addr / TEALE_ADDR first, then the
    /// mac app, then the Rust node default control port.
    pub async fn connect(addr: Option<&str>, json: bool) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .build()?;
        let mut candidates: Vec<String> = Vec::new();
        if let Some(a) = addr {
            candidates.push(normalize(a));
        }
        if let Ok(a) = std::env::var("TEALE_ADDR") {
            if !a.trim().is_empty() {
                candidates.push(normalize(&a));
            }
        }
        candidates.push("http://127.0.0.1:11435".to_string());
        candidates.push("http://127.0.0.1:11437".to_string());
        candidates.dedup();

        let mut last_err = String::new();
        for base in candidates {
            match client.get(format!("{base}/v1/app")).send().await {
                Ok(resp) if resp.status().is_success() => {
                    let flavor = match client.get(format!("{base}/v1/desktop/app")).send().await {
                        Ok(r) if r.status().is_success() => Flavor::Mac,
                        _ => Flavor::Node,
                    };
                    return Ok(Self {
                        base,
                        client,
                        json,
                        flavor,
                    });
                }
                Ok(resp) => last_err = format!("{base} answered {}", resp.status()),
                Err(e) => last_err = format!("{e}"),
            }
        }
        bail!(
            "no Teale daemon answered on 127.0.0.1:11435 (mac app) or :11437 (teale-node) - is one running? ({last_err})"
        )
    }

    pub async fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        let url = format!("{}{}", self.base, path);
        let mut req = match method {
            "GET" => self.client.get(&url),
            "POST" => self.client.post(&url),
            "PUT" => self.client.put(&url),
            "PATCH" => self.client.patch(&url),
            "DELETE" => self.client.delete(&url),
            _ => bail!("bad method {method}"),
        };
        if let Some(body) = body {
            req = req.json(&body);
        }
        let resp = req
            .send()
            .await
            .with_context(|| format!("daemon unreachable ({url})"))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        let payload: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if !status.is_success() {
            let message = payload
                .get("error")
                .and_then(|e| {
                    e.as_str()
                        .map(String::from)
                        .or_else(|| e.get("message").and_then(|m| m.as_str()).map(String::from))
                })
                .unwrap_or_else(|| {
                    if text.is_empty() {
                        status.to_string()
                    } else {
                        text.chars().take(300).collect()
                    }
                });
            bail!("{message}");
        }
        Ok(payload)
    }

    /// Print raw JSON with --json, else the human rendering.
    pub fn emit(&self, value: &Value, human: impl FnOnce(&Value) -> String) {
        if self.json {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_default()
            );
        } else {
            println!("{}", human(value));
        }
    }

    /// Convenience for mutation commands: raw JSON with --json, one line else.
    pub fn emit_ok(&self, value: &Value, line: impl Into<String>) {
        if self.json {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_default()
            );
        } else {
            println!("{}", line.into());
        }
    }

    pub fn flavor_route<'a>(&self, mac: &'a str, node: &'a str) -> &'a str {
        match self.flavor {
            Flavor::Mac => mac,
            Flavor::Node => node,
        }
    }
}

fn normalize(addr: &str) -> String {
    let a = addr.trim().trim_end_matches('/');
    if a.starts_with("http://") || a.starts_with("https://") {
        a.to_string()
    } else {
        format!("http://{a}")
    }
}

/// Parse "on"/"off" style state words.
pub fn parse_on_off(raw: &str, what: &str) -> Result<bool> {
    match raw {
        "on" | "true" | "enable" | "enabled" => Ok(true),
        "off" | "false" | "disable" | "disabled" => Ok(false),
        _ => Err(anyhow!("{what} must be on or off, got '{raw}'")),
    }
}

//! `teale-node pin …` — Tailscale-grade CLI for Private Inference Networks.
//! Talks to the local status server (which proxies management calls to the
//! gateway with this device's bearer), so it works while the node runs.

use anyhow::{anyhow, bail, Context, Result};
use clap::Subcommand;
use serde_json::Value;

#[derive(Subcommand, Debug)]
pub enum PinCommand {
    /// Show networks this device belongs to and their state.
    Status,
    /// Create a new network (requires a Teale-account-linked device).
    Create { name: String },
    /// Request to join a network with its PIN (admin approval follows).
    Join { code: String },
    /// List pending join requests (staff only).
    Requests {
        #[arg(long)]
        net: Option<String>,
    },
    /// Approve a pending device (admin only).
    Approve {
        device: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// Deny a pending device (admin only).
    Deny {
        device: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// List devices in a network.
    Devices {
        #[arg(long)]
        net: Option<String>,
    },
    /// Rename a device (staff).
    RenameDevice {
        device: String,
        name: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// Remove a device from the network (admin).
    RemoveDevice {
        device: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// Rotate the network join PIN (admin).
    RotateCode {
        #[arg(long)]
        net: Option<String>,
    },
    /// Show the current join PIN (admin).
    JoinCode {
        #[arg(long)]
        net: Option<String>,
    },
    /// Set a device's desired model loadout (staff).
    Models {
        device: String,
        /// Model ids; each becomes desiredState=loaded unless --state given.
        models: Vec<String>,
        #[arg(long, default_value = "loaded")]
        state: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// Usage totals (token counts — PINs have no credits).
    Usage {
        #[arg(long, default_value = "day")]
        by: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// Leave a network.
    Leave {
        #[arg(long)]
        net: Option<String>,
    },
}

pub struct LocalApi {
    base: String,
    client: reqwest::Client,
    json: bool,
}


/// Bearer key for the local API when it runs in authenticated mode (the Mac
/// app requires one while "Allow Network Access" is on). Resolution order:
/// TEALE_LOCAL_API_KEY env, then the app's api_keys.json (first active key).
fn local_api_key() -> Option<String> {
    if let Ok(k) = std::env::var("TEALE_LOCAL_API_KEY") {
        let k = k.trim().to_string();
        if !k.is_empty() {
            return Some(k);
        }
    }
    let candidates: Vec<std::path::PathBuf> = [
        std::env::var_os("HOME")
            .map(|h| std::path::PathBuf::from(h).join("Library/Application Support/Teale/api_keys.json")),
        std::env::var_os("APPDATA")
            .map(|h| std::path::PathBuf::from(h).join("Teale\api_keys.json")),
    ]
    .into_iter()
    .flatten()
    .collect();
    for path in candidates {
        let Ok(raw) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(keys) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        if let Some(key) = keys.as_array().and_then(|arr| {
            arr.iter()
                .find(|k| k["isActive"].as_bool().unwrap_or(false))
                .and_then(|k| k["key"].as_str())
                .map(|k| k.to_string())
        }) {
            return Some(key);
        }
    }
    None
}

impl LocalApi {
    pub fn new(control_port: u16, json: bool) -> Self {
        Self {
            base: format!("http://127.0.0.1:{control_port}"),
            client: reqwest::Client::new(),
            json,
        }
    }

    async fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        let url = format!("{}{}", self.base, path);
        let mut req = match method {
            "GET" => self.client.get(&url),
            "POST" => self.client.post(&url),
            "PUT" => self.client.put(&url),
            "PATCH" => self.client.patch(&url),
            "DELETE" => self.client.delete(&url),
            _ => bail!("bad method"),
        };
        if let Some(key) = local_api_key() {
            req = req.bearer_auth(key);
        }
        if let Some(body) = body {
            req = req.json(&body);
        }
        let resp = req
            .send()
            .await
            .with_context(|| format!("is teale-node running? ({url})"))?;
        let status = resp.status();
        let payload: Value = resp.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            let message = payload
                .get("error")
                .map(|e| e.to_string())
                .unwrap_or_else(|| status.to_string());
            bail!("{message}");
        }
        Ok(payload)
    }

    fn overview_networks(overview: &Value) -> Vec<(String, String, String)> {
        let mut nets: Vec<(String, String, String)> = Vec::new(); // (id, name, membership)
        for n in overview["networks"].as_array().into_iter().flatten() {
            nets.push((
                n["pinId"].as_str().unwrap_or_default().to_string(),
                n["name"].as_str().unwrap_or_default().to_string(),
                n["membership"].as_str().unwrap_or_default().to_string(),
            ));
        }
        for s in overview["staff"].as_array().into_iter().flatten() {
            let id = s["pinId"].as_str().unwrap_or_default().to_string();
            if !nets.iter().any(|(existing, ..)| existing == &id) {
                nets.push((
                    id,
                    s["name"].as_str().unwrap_or_default().to_string(),
                    format!("staff:{}", s["role"].as_str().unwrap_or("?")),
                ));
            }
        }
        nets
    }

    /// Resolve --net (name or id, unambiguous prefix ok) or default to the
    /// sole network.
    async fn resolve_net(&self, net: Option<&str>) -> Result<String> {
        let overview = self.call("GET", "/v1/app/pins", None).await?;
        let nets = Self::overview_networks(&overview);
        match net {
            Some(query) => {
                let matches: Vec<_> = nets
                    .iter()
                    .filter(|(id, name, _)| id == query || name == query || id.starts_with(query))
                    .collect();
                match matches.len() {
                    1 => Ok(matches[0].0.clone()),
                    0 => bail!("no network matches '{query}'"),
                    _ => bail!("'{query}' is ambiguous; use the full network id"),
                }
            }
            None => match nets.len() {
                1 => Ok(nets[0].0.clone()),
                0 => bail!("this device is not in any network — `teale-node pin join <PIN>`"),
                _ => bail!(
                    "multiple networks; pick one with --net <name>: {}",
                    nets.iter()
                        .map(|(_, name, _)| name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            },
        }
    }

    fn emit(&self, value: &Value, human: impl FnOnce(&Value) -> String) {
        if self.json {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_default()
            );
        } else {
            println!("{}", human(value));
        }
    }
}

pub fn render_status(overview: &Value) -> String {
    let nets = LocalApi::overview_networks(overview);
    if nets.is_empty() {
        return "no private networks — join one with `teale-node pin join <PIN>`".to_string();
    }
    let mut out = String::new();
    for (id, name, membership) in nets {
        out.push_str(&format!("{name:24} {membership:14} {id}\n"));
    }
    if let Some(pending) = overview["pendingUsageBatches"].as_u64() {
        if pending > 0 {
            out.push_str(&format!("({pending} usage batch(es) awaiting delivery)\n"));
        }
    }
    out.trim_end().to_string()
}

pub fn render_members(members: &Value, filter: Option<&str>) -> String {
    let rows: Vec<&Value> = members
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|m| filter.is_none_or(|f| m["status"].as_str() == Some(f)))
                .collect()
        })
        .unwrap_or_default();
    if rows.is_empty() {
        return match filter {
            Some("pending") => "no pending join requests".to_string(),
            _ => "no devices".to_string(),
        };
    }
    let mut out = format!(
        "{:26} {:10} {:8} {:20} {}\n",
        "DEVICE", "STATUS", "SERVES", "MODELS", "ID"
    );
    for m in rows {
        let models = m["loadedModels"]
            .as_str()
            .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok())
            .unwrap_or_default();
        out.push_str(&format!(
            "{:26} {:10} {:8} {:20} {}\n",
            m["displayName"].as_str().unwrap_or("-"),
            m["status"].as_str().unwrap_or("?"),
            if m["servesModels"].as_bool().unwrap_or(false) {
                "yes"
            } else {
                "no"
            },
            if models.is_empty() {
                "-".to_string()
            } else {
                models.join(",")
            },
            m["deviceId"].as_str().unwrap_or("?"),
        ));
    }
    out.trim_end().to_string()
}

pub fn render_usage(usage: &Value, by: &str) -> String {
    let totals = usage["totals"].as_array().cloned().unwrap_or_default();
    if totals.is_empty() {
        return "no usage recorded".to_string();
    }
    let mut out = format!(
        "{:28} {:>10} {:>12} {:>12}\n",
        by.to_uppercase(),
        "REQS",
        "TOKENS IN",
        "TOKENS OUT"
    );
    for row in totals {
        out.push_str(&format!(
            "{:28} {:>10} {:>12} {:>12}\n",
            row["key"].as_str().unwrap_or("?"),
            row["requests"].as_i64().unwrap_or(0),
            row["tokensIn"].as_i64().unwrap_or(0),
            row["tokensOut"].as_i64().unwrap_or(0),
        ));
    }
    out.trim_end().to_string()
}

pub async fn run(command: PinCommand, control_port: u16, json: bool) -> Result<()> {
    let api = LocalApi::new(control_port, json);
    match command {
        PinCommand::Status => {
            let overview = api.call("GET", "/v1/app/pins", None).await?;
            api.emit(&overview, render_status);
        }
        PinCommand::Create { name } => {
            let created = api
                .call(
                    "POST",
                    "/v1/app/pins/create",
                    Some(serde_json::json!({ "name": name })),
                )
                .await?;
            api.emit(&created, |v| {
                format!(
                    "created network '{}'\njoin PIN: {}  (share it; you approve each device)",
                    v["name"].as_str().unwrap_or("?"),
                    v["joinCode"].as_str().unwrap_or("?"),
                )
            });
        }
        PinCommand::Join { code } => {
            // Join PINs are 10 chars from the Crockford-ish alphabet (dashes
            // optional): XXXX-XXXX-XX. The gateway deliberately answers 202
            // to everything (anti-oracle), so catch malformed input here -
            // a wrong code otherwise fails silently.
            const JOIN_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789";
            let normalized: String = code
                .chars()
                .filter(|c| *c != '-')
                .map(|c| c.to_ascii_uppercase())
                .collect();
            if normalized.len() != 10
                || !normalized
                    .bytes()
                    .all(|b| JOIN_ALPHABET.contains(&b))
            {
                bail!(
                    "'{code}' is not a join PIN (expected XXXX-XXXX-XX). \
                     If that's a network id, ask the network admin for the current join PIN."
                );
            }
            let resp = api
                .call(
                    "POST",
                    "/v1/app/pins/join",
                    Some(serde_json::json!({ "code": code })),
                )
                .await?;
            api.emit(&resp, |_| {
                "join request submitted — waiting for admin approval".to_string()
            });
        }
        PinCommand::Requests { net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            let members = api
                .call("GET", &format!("/v1/app/pins/{id}/members"), None)
                .await?;
            api.emit(&members, |v| render_members(v, Some("pending")));
        }
        PinCommand::Approve { device, net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            api.call(
                "POST",
                &format!("/v1/app/pins/{id}/members/{device}/approve"),
                None,
            )
            .await?;
            println!("approved {device}");
        }
        PinCommand::Deny { device, net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            api.call(
                "POST",
                &format!("/v1/app/pins/{id}/members/{device}/deny"),
                None,
            )
            .await?;
            println!("denied {device}");
        }
        PinCommand::Devices { net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            let members = api
                .call("GET", &format!("/v1/app/pins/{id}/members"), None)
                .await?;
            api.emit(&members, |v| render_members(v, None));
        }
        PinCommand::RenameDevice { device, name, net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            api.call(
                "PATCH",
                &format!("/v1/app/pins/{id}/members/{device}"),
                Some(serde_json::json!({ "displayName": name })),
            )
            .await?;
            println!("renamed {device}");
        }
        PinCommand::RemoveDevice { device, net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            api.call(
                "DELETE",
                &format!("/v1/app/pins/{id}/members/{device}"),
                None,
            )
            .await?;
            println!("removed {device}");
        }
        PinCommand::RotateCode { net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            let resp = api
                .call("POST", &format!("/v1/app/pins/{id}/rotate-code"), None)
                .await?;
            api.emit(&resp, |v| {
                format!("new join PIN: {}", v["joinCode"].as_str().unwrap_or("?"))
            });
        }
        PinCommand::JoinCode { net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            let resp = api
                .call("GET", &format!("/v1/app/pins/{id}/join-code"), None)
                .await?;
            api.emit(&resp, |v| {
                format!("join PIN: {}", v["joinCode"].as_str().unwrap_or("?"))
            });
        }
        PinCommand::Models {
            device,
            models,
            state,
            net,
        } => {
            if !matches!(state.as_str(), "loaded" | "downloaded" | "none") {
                return Err(anyhow!("--state must be loaded, downloaded, or none"));
            }
            let id = api.resolve_net(net.as_deref()).await?;
            let payload = serde_json::json!({
                "models": models
                    .iter()
                    .map(|m| serde_json::json!({ "modelId": m, "desiredState": state }))
                    .collect::<Vec<_>>(),
            });
            api.call(
                "PUT",
                &format!("/v1/app/pins/{id}/models/{device}"),
                Some(payload),
            )
            .await?;
            println!(
                "desired loadout set for {device}: {} → {state}",
                models.join(", ")
            );
        }
        PinCommand::Usage { by, net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            let usage = api
                .call("GET", &format!("/v1/app/pins/{id}/usage?by={by}"), None)
                .await?;
            api.emit(&usage, |v| render_usage(v, &by));
        }
        PinCommand::Leave { net } => {
            let id = api.resolve_net(net.as_deref()).await?;
            api.call("POST", &format!("/v1/app/pins/{id}/leave"), None)
                .await?;
            println!("left the network");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_rendering() {
        let overview = serde_json::json!({
            "networks": [
                {"pinId": "pin-1", "name": "Hou", "membership": "active"},
                {"pinId": "pin-2", "name": "client-x", "membership": "pending"},
            ],
            "staff": [{"pinId": "pin-1", "name": "Hou", "role": "admin"}],
            "pendingUsageBatches": 2,
        });
        let out = render_status(&overview);
        assert!(out.contains("Hou"));
        assert!(out.contains("active"));
        assert!(out.contains("pending"));
        assert!(out.contains("2 usage batch"));
    }

    #[test]
    fn members_rendering_filters_pending() {
        let members = serde_json::json!([
            {"deviceId": "dev-a", "displayName": "Front Desk", "status": "active",
             "servesModels": true, "loadedModels": "[\"qwen3-4b\"]"},
            {"deviceId": "dev-b", "displayName": null, "status": "pending",
             "servesModels": true, "loadedModels": "[]"},
        ]);
        let all = render_members(&members, None);
        assert!(all.contains("Front Desk") && all.contains("dev-b"));
        assert!(all.contains("qwen3-4b"));
        let pending = render_members(&members, Some("pending"));
        assert!(!pending.contains("Front Desk") && pending.contains("dev-b"));
        assert_eq!(
            render_members(&serde_json::json!([]), Some("pending")),
            "no pending join requests"
        );
    }

    #[test]
    fn usage_rendering() {
        let usage = serde_json::json!({
            "totals": [{"key": "2026-07-04", "requests": 12, "tokensIn": 3400, "tokensOut": 900}],
        });
        let out = render_usage(&usage, "day");
        assert!(out.contains("2026-07-04"));
        assert!(out.contains("3400"));
        assert_eq!(
            render_usage(&serde_json::json!({"totals": []}), "day"),
            "no usage recorded"
        );
    }
}

//! `teale pin ...` — Private Inference Network management, plus the
//! exit-node offer/route group. Talks to the local daemon's /v1/app/pins
//! routes (shared contract between the mac app and teale-node), so it works
//! against either while it runs.

use anyhow::{anyhow, bail, Result};
use clap::Subcommand;
use serde_json::Value;

use crate::api::{parse_on_off, LocalApi};

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
    /// Exit-node data plane: offer this device, or route traffic out via a peer.
    #[command(subcommand)]
    Exit(ExitCommand),
}

#[derive(Subcommand, Debug)]
pub enum ExitCommand {
    /// Offer (or stop offering) this device as an exit node for a network.
    Offer {
        state: String,
        #[arg(long)]
        net: Option<String>,
    },
    /// Route local traffic out via a network exit node (SOCKS5 on 127.0.0.1:17890).
    Start {
        #[arg(long)]
        net: Option<String>,
        /// Prefer a specific provider device id.
        #[arg(long)]
        device: Option<String>,
    },
    /// Stop exit routing.
    Stop,
    /// Show exit routing status.
    Status,
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
pub async fn resolve_net(api: &LocalApi, net: Option<&str>) -> Result<String> {
    let overview = api.call("GET", "/v1/app/pins", None).await?;
    let nets = overview_networks(&overview);
    match net {
        Some(query) => {
            let matches: Vec<_> = nets
                .iter()
                .filter(|(id, name, _)| id == query || name == query || id.starts_with(query))
                .collect();
            match matches.len() {
                1 => Ok(matches[0].0.clone()),
                0 => bail!("no network matches '{query}'"),
                _ => bail!(
                    "'{query}' is ambiguous; use the full network id: {}",
                    matches
                        .iter()
                        .map(|(id, name, _)| format!("{name} ({id})"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            }
        }
        None => match nets.len() {
            1 => Ok(nets[0].0.clone()),
            0 => bail!("this device is not in any network — `teale pin join <PIN>`"),
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

pub fn render_status(overview: &Value) -> String {
    let nets = overview_networks(overview);
    if nets.is_empty() {
        return "no private networks — join one with `teale pin join <PIN>`".to_string();
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

fn render_exit_status(v: &Value) -> String {
    let state = v["state"].as_str().unwrap_or("off");
    match state {
        "off" => "exit routing off".to_string(),
        _ => {
            let mut out = format!("exit routing: {state}");
            if let Some(pin) = v["pinId"].as_str() {
                out.push_str(&format!("\nnetwork:    {pin}"));
            }
            if let Some(via) = v["viaDevice"].as_str() {
                out.push_str(&format!("\nvia:        {via}"));
            }
            if let (Some(host), Some(port)) = (v["host"].as_str(), v["port"].as_i64()) {
                out.push_str(&format!("\nproxy:      socks5://{host}:{port}"));
            }
            if let Some(err) = v["error"].as_str() {
                if !err.is_empty() {
                    out.push_str(&format!("\nerror:      {err}"));
                }
            }
            out
        }
    }
}

pub async fn run(api: &LocalApi, command: PinCommand) -> Result<()> {
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
            let id = resolve_net(api, net.as_deref()).await?;
            let members = api
                .call("GET", &format!("/v1/app/pins/{id}/members"), None)
                .await?;
            api.emit(&members, |v| render_members(v, Some("pending")));
        }
        PinCommand::Approve { device, net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let resp = api
                .call(
                    "POST",
                    &format!("/v1/app/pins/{id}/members/{device}/approve"),
                    None,
                )
                .await?;
            api.emit_ok(&resp, format!("approved {device}"));
        }
        PinCommand::Deny { device, net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let resp = api
                .call(
                    "POST",
                    &format!("/v1/app/pins/{id}/members/{device}/deny"),
                    None,
                )
                .await?;
            api.emit_ok(&resp, format!("denied {device}"));
        }
        PinCommand::Devices { net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let members = api
                .call("GET", &format!("/v1/app/pins/{id}/members"), None)
                .await?;
            api.emit(&members, |v| render_members(v, None));
        }
        PinCommand::RenameDevice { device, name, net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let resp = api
                .call(
                    "PATCH",
                    &format!("/v1/app/pins/{id}/members/{device}"),
                    Some(serde_json::json!({ "displayName": name })),
                )
                .await?;
            api.emit_ok(&resp, format!("renamed {device}"));
        }
        PinCommand::RemoveDevice { device, net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let resp = api
                .call(
                    "DELETE",
                    &format!("/v1/app/pins/{id}/members/{device}"),
                    None,
                )
                .await?;
            api.emit_ok(&resp, format!("removed {device}"));
        }
        PinCommand::RotateCode { net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let resp = api
                .call("POST", &format!("/v1/app/pins/{id}/rotate-code"), None)
                .await?;
            api.emit(&resp, |v| {
                format!("new join PIN: {}", v["joinCode"].as_str().unwrap_or("?"))
            });
        }
        PinCommand::JoinCode { net } => {
            let id = resolve_net(api, net.as_deref()).await?;
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
            let id = resolve_net(api, net.as_deref()).await?;
            let payload = serde_json::json!({
                "models": models
                    .iter()
                    .map(|m| serde_json::json!({ "modelId": m, "desiredState": state }))
                    .collect::<Vec<_>>(),
            });
            let resp = api
                .call(
                    "PUT",
                    &format!("/v1/app/pins/{id}/models/{device}"),
                    Some(payload),
                )
                .await?;
            api.emit_ok(
                &resp,
                format!(
                    "desired loadout set for {device}: {} → {state}",
                    models.join(", ")
                ),
            );
        }
        PinCommand::Usage { by, net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let usage = api
                .call("GET", &format!("/v1/app/pins/{id}/usage?by={by}"), None)
                .await?;
            api.emit(&usage, |v| render_usage(v, &by));
        }
        PinCommand::Leave { net } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let resp = api
                .call("POST", &format!("/v1/app/pins/{id}/leave"), None)
                .await?;
            api.emit_ok(&resp, "left the network");
        }
        PinCommand::Exit(exit) => run_exit(api, exit).await?,
    }
    Ok(())
}

async fn run_exit(api: &LocalApi, command: ExitCommand) -> Result<()> {
    match command {
        ExitCommand::Offer { state, net } => {
            let on = parse_on_off(&state, "offer state")?;
            let id = resolve_net(api, net.as_deref()).await?;
            let settings = api.call("GET", "/v1/app/pins/settings/local", None).await?;
            let mut pins: Vec<String> = settings["exitNodePins"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|p| p.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            if on && !pins.iter().any(|p| p == &id) {
                pins.push(id.clone());
            }
            if !on {
                pins.retain(|p| p != &id);
            }
            let resp = api
                .call(
                    "POST",
                    "/v1/app/pins/settings/local",
                    Some(serde_json::json!({ "exitNodePins": pins })),
                )
                .await?;
            api.emit_ok(
                &resp,
                if on {
                    format!("offering exit for network {id}")
                } else {
                    format!("exit offer withdrawn for network {id}")
                },
            );
        }
        ExitCommand::Start { net, device } => {
            let id = resolve_net(api, net.as_deref()).await?;
            let mut body = serde_json::json!({ "pinId": id });
            if let Some(device) = device {
                body["deviceId"] = serde_json::Value::String(device);
            }
            let resp = api
                .call("POST", "/v1/app/pins/exit/start", Some(body))
                .await?;
            api.emit(&resp, render_exit_status);
        }
        ExitCommand::Stop => {
            let resp = api.call("POST", "/v1/app/pins/exit/stop", None).await?;
            api.emit_ok(&resp, "exit routing stopped");
        }
        ExitCommand::Status => {
            let resp = api.call("GET", "/v1/app/pins/exit/status", None).await?;
            api.emit(&resp, render_exit_status);
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

    #[test]
    fn exit_status_rendering() {
        let listening = serde_json::json!({
            "state": "listening", "pinId": "pin-1", "viaDevice": "ath-64",
            "host": "127.0.0.1", "port": 17890,
        });
        let out = render_exit_status(&listening);
        assert!(out.contains("listening"));
        assert!(out.contains("ath-64"));
        assert!(out.contains("socks5://127.0.0.1:17890"));
        assert_eq!(
            render_exit_status(&serde_json::json!({"state": "off"})),
            "exit routing off"
        );
    }
}

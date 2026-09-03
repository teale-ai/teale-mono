//! `teale mcp` — stdio MCP server: agents drive the local Teale daemon
//! natively (newline-delimited JSON-RPC 2.0 on stdin/stdout).
//!
//! One tool per CLI command group, thin over the same loopback API. Launch
//! with: teale mcp   (respects --addr / TEALE_ADDR)

use anyhow::Result;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::api::{Flavor, LocalApi};
use crate::pin_cmds::resolve_net;

pub async fn serve(api: LocalApi) -> Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();
    let mut lines = stdin.lines();
    while let Some(line) = lines.next_line().await? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let method = msg["method"].as_str().unwrap_or("");
        let id = msg.get("id").cloned();
        let response = match method {
            "initialize" => id.map(|id| {
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "protocolVersion": msg["params"]["protocolVersion"]
                            .as_str()
                            .unwrap_or("2024-11-05"),
                        "capabilities": { "tools": {} },
                        "serverInfo": { "name": "teale", "version": env!("CARGO_PKG_VERSION") },
                    }
                })
            }),
            "ping" => id.map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": {} })),
            "tools/list" => {
                id.map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": { "tools": tools() } }))
            }
            "tools/call" => match id {
                Some(id) => {
                    let name = msg["params"]["name"].as_str().unwrap_or("");
                    let args = msg["params"]["arguments"].clone();
                    let result = call_tool(&api, name, &args).await;
                    Some(match result {
                        Ok(text) => json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "result": { "content": [{ "type": "text", "text": text }] }
                        }),
                        Err(e) => json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "result": {
                                "content": [{ "type": "text", "text": format!("{e:#}") }],
                                "isError": true,
                            }
                        }),
                    })
                }
                None => None,
            },
            // Notifications (initialized, cancelled, ...) need no reply; an
            // unknown request method gets Method not found.
            _ => id.map(|id| {
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32601, "message": format!("method not found: {method}") },
                })
            }),
        };
        if let Some(response) = response {
            let mut buf = serde_json::to_string(&response).unwrap_or_default();
            buf.push('\n');
            stdout.write_all(buf.as_bytes()).await?;
            stdout.flush().await?;
        }
    }
    Ok(())
}

fn tool(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
        }
    })
}

fn net_prop() -> Value {
    json!({ "type": "string", "description": "network name or id (optional when only one)" })
}

fn tools() -> Value {
    json!([
        tool(
            "teale_status",
            "Node snapshot: daemon state, loaded model, wallet, account.",
            json!({}),
            &[]
        ),
        tool(
            "teale_supply",
            "Turn compute supply on or off.",
            json!({
                "on": { "type": "boolean", "description": "true = supply compute" }
            }),
            &["on"]
        ),
        tool(
            "teale_models_list",
            "List models the daemon reports.",
            json!({}),
            &[]
        ),
        tool(
            "teale_model_load",
            "Load a model into the inference engine.",
            json!({
                "model": { "type": "string" },
                "download": { "type": "boolean", "description": "download first if missing" }
            }),
            &["model"]
        ),
        tool(
            "teale_model_download",
            "Download a model without loading it.",
            json!({
                "model": { "type": "string" }
            }),
            &["model"]
        ),
        tool(
            "teale_model_unload",
            "Unload the current model.",
            json!({}),
            &[]
        ),
        tool("teale_wallet_balance", "Credit balance.", json!({}), &[]),
        tool(
            "teale_wallet_transactions",
            "Recent wallet transactions.",
            json!({}),
            &[]
        ),
        tool(
            "teale_wallet_send",
            "Send credits to a peer node.",
            json!({
                "amount": { "type": "number" },
                "peer_id": { "type": "string" },
                "memo": { "type": "string" }
            }),
            &["amount", "peer_id"]
        ),
        tool(
            "teale_account_summary",
            "Account summary (identity, plan, devices).",
            json!({}),
            &[]
        ),
        tool(
            "teale_peers",
            "Connected WAN peers (mac app).",
            json!({}),
            &[]
        ),
        tool(
            "teale_settings_get",
            "Show the daemon's current settings.",
            json!({}),
            &[]
        ),
        tool(
            "teale_settings_set",
            "Set one local setting (snake_case key).",
            json!({
                "key": { "type": "string", "description": "e.g. wan_enabled" },
                "value": { "type": ["string", "number", "boolean"] }
            }),
            &["key", "value"]
        ),
        tool(
            "teale_pin_status",
            "Networks this device belongs to and their state.",
            json!({}),
            &[]
        ),
        tool(
            "teale_pin_create",
            "Create a private inference network; returns its join PIN.",
            json!({
                "name": { "type": "string" }
            }),
            &["name"]
        ),
        tool(
            "teale_pin_join",
            "Request to join a network with its join PIN (admin approval follows).",
            json!({
                "code": { "type": "string" }
            }),
            &["code"]
        ),
        tool(
            "teale_pin_requests",
            "List pending join requests (staff).",
            json!({
                "net": net_prop()
            }),
            &[]
        ),
        tool(
            "teale_pin_approve",
            "Approve a pending device (admin).",
            json!({
                "device": { "type": "string" }, "net": net_prop()
            }),
            &["device"]
        ),
        tool(
            "teale_pin_deny",
            "Deny a pending device (admin).",
            json!({
                "device": { "type": "string" }, "net": net_prop()
            }),
            &["device"]
        ),
        tool(
            "teale_pin_devices",
            "List devices in a network.",
            json!({
                "net": net_prop()
            }),
            &[]
        ),
        tool(
            "teale_pin_rotate_code",
            "Rotate the network join PIN (admin).",
            json!({
                "net": net_prop()
            }),
            &[]
        ),
        tool(
            "teale_pin_join_code",
            "Show the current join PIN (admin).",
            json!({
                "net": net_prop()
            }),
            &[]
        ),
        tool(
            "teale_pin_usage",
            "Usage totals (token counts; PINs have no credits).",
            json!({
                "by": { "type": "string", "description": "day | week | month (default day)" },
                "net": net_prop()
            }),
            &[]
        ),
        tool(
            "teale_pin_leave",
            "Leave a network.",
            json!({
                "net": net_prop()
            }),
            &[]
        ),
        tool(
            "teale_exit_offer",
            "Offer (or stop offering) this device as an exit node for a network.",
            json!({
                "on": { "type": "boolean" }, "net": net_prop()
            }),
            &["on"]
        ),
        tool(
            "teale_exit_start",
            "Route local traffic out via a network exit node (SOCKS5 on 127.0.0.1:17890).",
            json!({
                "net": net_prop(),
                "device": { "type": "string", "description": "preferred provider device id" }
            }),
            &[]
        ),
        tool("teale_exit_stop", "Stop exit routing.", json!({}), &[]),
        tool("teale_exit_status", "Exit routing status.", json!({}), &[]),
    ])
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

async fn call_tool(api: &LocalApi, name: &str, args: &Value) -> Result<String> {
    let net = || args["net"].as_str();
    let text = match name {
        "teale_status" => pretty(&api.call("GET", "/v1/app", None).await?),
        "teale_supply" => {
            let on = args["on"].as_bool().unwrap_or(false);
            let value = match api.flavor {
                Flavor::Mac => {
                    api.call(
                        "POST",
                        "/v1/desktop/app/supply",
                        Some(json!({ "enabled": on })),
                    )
                    .await?
                }
                Flavor::Node => {
                    api.call(
                        "POST",
                        if on {
                            "/v1/app/service/resume"
                        } else {
                            "/v1/app/service/pause"
                        },
                        None,
                    )
                    .await?
                }
            };
            pretty(&value)
        }
        "teale_models_list" => pretty(&api.call("GET", "/v1/models", None).await?),
        "teale_model_load" => pretty(
            &api.call(
                "POST",
                "/v1/app/models/load",
                Some(json!({
                    "model": args["model"].as_str().unwrap_or_default(),
                    "download_if_needed": args["download"].as_bool().unwrap_or(false),
                })),
            )
            .await?,
        ),
        "teale_model_download" => pretty(
            &api.call(
                "POST",
                "/v1/app/models/download",
                Some(json!({ "model": args["model"].as_str().unwrap_or_default() })),
            )
            .await?,
        ),
        "teale_model_unload" => pretty(&api.call("POST", "/v1/app/models/unload", None).await?),
        "teale_wallet_balance" => pretty(&api.call("GET", "/v1/app/wallet", None).await?),
        "teale_wallet_transactions" => {
            pretty(&api.call("GET", "/v1/app/wallet/transactions", None).await?)
        }
        "teale_wallet_send" => {
            let amount = args["amount"].as_f64().unwrap_or(0.0);
            if amount <= 0.0 {
                anyhow::bail!("amount must be positive");
            }
            pretty(
                &api.call(
                    "POST",
                    "/v1/app/wallet/send",
                    Some(json!({
                        "amount": amount,
                        "peer_id": args["peer_id"].as_str().unwrap_or_default(),
                        "memo": args["memo"].as_str(),
                    })),
                )
                .await?,
            )
        }
        "teale_account_summary" => {
            let path = api.flavor_route("/v1/desktop/app/account", "/v1/app/account");
            pretty(&api.call("GET", path, None).await?)
        }
        "teale_peers" => pretty(&api.call("GET", "/v1/app/peers", None).await?),
        "teale_settings_get" => {
            let snapshot = api.call("GET", "/v1/app", None).await?;
            pretty(if snapshot["settings"].is_object() {
                &snapshot["settings"]
            } else {
                &snapshot
            })
        }
        "teale_settings_set" => {
            let key = args["key"].as_str().unwrap_or_default();
            if key.is_empty() {
                anyhow::bail!("key is required");
            }
            pretty(
                &api.call(
                    "PATCH",
                    "/v1/app/settings",
                    Some(json!({ key: args["value"].clone() })),
                )
                .await?,
            )
        }
        "teale_pin_status" => pretty(&api.call("GET", "/v1/app/pins", None).await?),
        "teale_pin_create" => pretty(
            &api.call(
                "POST",
                "/v1/app/pins/create",
                Some(json!({ "name": args["name"].as_str().unwrap_or_default() })),
            )
            .await?,
        ),
        "teale_pin_join" => pretty(
            &api.call(
                "POST",
                "/v1/app/pins/join",
                Some(json!({ "code": args["code"].as_str().unwrap_or_default() })),
            )
            .await?,
        ),
        "teale_pin_requests" => {
            let id = resolve_net(api, net()).await?;
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/members"), None)
                    .await?,
            )
        }
        "teale_pin_approve" | "teale_pin_deny" => {
            let id = resolve_net(api, net()).await?;
            let action = if name == "teale_pin_approve" {
                "approve"
            } else {
                "deny"
            };
            let device = args["device"].as_str().unwrap_or_default();
            pretty(
                &api.call(
                    "POST",
                    &format!("/v1/app/pins/{id}/members/{device}/{action}"),
                    None,
                )
                .await?,
            )
        }
        "teale_pin_devices" => {
            let id = resolve_net(api, net()).await?;
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/members"), None)
                    .await?,
            )
        }
        "teale_pin_rotate_code" => {
            let id = resolve_net(api, net()).await?;
            pretty(
                &api.call("POST", &format!("/v1/app/pins/{id}/rotate-code"), None)
                    .await?,
            )
        }
        "teale_pin_join_code" => {
            let id = resolve_net(api, net()).await?;
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/join-code"), None)
                    .await?,
            )
        }
        "teale_pin_usage" => {
            let id = resolve_net(api, net()).await?;
            let by = args["by"].as_str().unwrap_or("day");
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/usage?by={by}"), None)
                    .await?,
            )
        }
        "teale_pin_leave" => {
            let id = resolve_net(api, net()).await?;
            pretty(
                &api.call("POST", &format!("/v1/app/pins/{id}/leave"), None)
                    .await?,
            )
        }
        "teale_exit_offer" => {
            let on = args["on"].as_bool().unwrap_or(false);
            let id = resolve_net(api, net()).await?;
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
            pretty(
                &api.call(
                    "POST",
                    "/v1/app/pins/settings/local",
                    Some(json!({ "exitNodePins": pins })),
                )
                .await?,
            )
        }
        "teale_exit_start" => {
            let id = resolve_net(api, net()).await?;
            let mut body = json!({ "pinId": id });
            if let Some(device) = args["device"].as_str() {
                body["deviceId"] = Value::String(device.to_string());
            }
            pretty(
                &api.call("POST", "/v1/app/pins/exit/start", Some(body))
                    .await?,
            )
        }
        "teale_exit_stop" => pretty(&api.call("POST", "/v1/app/pins/exit/stop", None).await?),
        "teale_exit_status" => pretty(&api.call("GET", "/v1/app/pins/exit/status", None).await?),
        _ => anyhow::bail!("unknown tool: {name}"),
    };
    Ok(text)
}

//! `teale mcp` — stdio MCP server: agents drive the local Teale daemon
//! natively (newline-delimited JSON-RPC 2.0 on stdin/stdout).
//!
//! One tool per CLI command group, thin over the same loopback API. Launch
//! with: teale mcp   (respects --addr / TEALE_ADDR)
//!
//! By default only read-only tools are listed and callable. Tools that
//! change state (supply, models, wallet sends, settings, PIN membership and
//! admin actions, exit routing) require `teale mcp --allow-mutations`;
//! without it they are not listed and calls to them are refused.

use anyhow::{bail, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::api::{Flavor, LocalApi};
use crate::pin_cmds::resolve_net;

/// Tools that change local or account state. Hidden and refused unless the
/// server runs with `--allow-mutations`.
const MUTATING_TOOLS: &[&str] = &[
    "teale_supply",
    "teale_model_load",
    "teale_model_download",
    "teale_model_unload",
    "teale_wallet_send",
    "teale_settings_set",
    "teale_pin_create",
    "teale_pin_join",
    "teale_pin_approve",
    "teale_pin_deny",
    "teale_pin_rotate_code",
    "teale_pin_leave",
    "teale_exit_offer",
    "teale_exit_start",
    "teale_exit_stop",
];

fn is_mutating(name: &str) -> bool {
    MUTATING_TOOLS.contains(&name)
}

fn check_allowed(name: &str, allow_mutations: bool) -> Result<()> {
    if is_mutating(name) && !allow_mutations {
        bail!(
            "{name} changes state and is disabled; restart the server with \
             `teale mcp --allow-mutations` to enable it"
        );
    }
    Ok(())
}

/// Decode one stdin line into a JSON-RPC message, or the error response to
/// send back (`-32700` parse error / `-32600` invalid request, id null).
fn decode_line(line: &str) -> std::result::Result<Value, Value> {
    match serde_json::from_str::<Value>(line) {
        Ok(msg) if msg.is_object() => Ok(msg),
        Ok(_) => Err(rpc_error(Value::Null, -32600, "invalid request")),
        Err(e) => {
            let message = format!("parse error: {e}");
            Err(rpc_error(Value::Null, -32700, &message))
        }
    }
}

fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

pub async fn serve(api: LocalApi, allow_mutations: bool) -> Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();
    let mut lines = stdin.lines();
    while let Some(line) = lines.next_line().await? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let msg = match decode_line(line) {
            Ok(msg) => msg,
            Err(response) => {
                let mut buf = serde_json::to_string(&response).unwrap_or_default();
                buf.push('\n');
                stdout.write_all(buf.as_bytes()).await?;
                stdout.flush().await?;
                continue;
            }
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
                let list = tools(allow_mutations);
                id.map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": { "tools": list } }))
            }
            "tools/call" => match id {
                Some(id) => {
                    let name = msg["params"]["name"].as_str().unwrap_or("");
                    let args = msg["params"]["arguments"].clone();
                    let result = call_tool(&api, allow_mutations, name, &args).await;
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
            _ => id.map(|id| rpc_error(id, -32601, &format!("method not found: {method}"))),
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

fn all_tools() -> Value {
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

/// The tools advertised by `tools/list`: read-only ones always, mutating
/// ones only with `--allow-mutations`.
fn tools(allow_mutations: bool) -> Value {
    let mut all = all_tools();
    if !allow_mutations {
        if let Some(list) = all.as_array_mut() {
            list.retain(|t| !is_mutating(t["name"].as_str().unwrap_or_default()));
        }
    }
    all
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

fn require_bool(args: &Value, key: &str) -> Result<bool> {
    match args[key].as_bool() {
        Some(value) => Ok(value),
        None => bail!("`{key}` is required and must be true or false"),
    }
}

fn require_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    match args[key].as_str() {
        Some(value) if !value.trim().is_empty() => Ok(value),
        _ => bail!("`{key}` is required and must be a non-empty string"),
    }
}

/// Percent-encode one URL path segment (RFC 3986 unreserved characters pass
/// through). Empty, `.` and `..` are rejected: URL normalization would turn
/// them (even percent-encoded) into a different path.
fn path_segment(raw: &str) -> Result<String> {
    if raw.is_empty() || raw == "." || raw == ".." {
        bail!("invalid path segment '{raw}'");
    }
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(char::from(b))
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    Ok(out)
}

async fn net_segment(api: &LocalApi, net: Option<&str>) -> Result<String> {
    path_segment(&resolve_net(api, net).await?)
}

async fn call_tool(
    api: &LocalApi,
    allow_mutations: bool,
    name: &str,
    args: &Value,
) -> Result<String> {
    check_allowed(name, allow_mutations)?;
    let net = || args["net"].as_str();
    let text = match name {
        "teale_status" => pretty(&api.call("GET", "/v1/app", None).await?),
        "teale_supply" => {
            let on = require_bool(args, "on")?;
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
                    "model": require_str(args, "model")?,
                    "download_if_needed": args["download"].as_bool().unwrap_or(false),
                })),
            )
            .await?,
        ),
        "teale_model_download" => pretty(
            &api.call(
                "POST",
                "/v1/app/models/download",
                Some(json!({ "model": require_str(args, "model")? })),
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
                        "peer_id": require_str(args, "peer_id")?,
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
            let key = require_str(args, "key")?;
            let value = match args.get("value") {
                Some(value) if !value.is_null() => value.clone(),
                _ => bail!("`value` is required"),
            };
            pretty(
                &api.call("PATCH", "/v1/app/settings", Some(json!({ key: value })))
                    .await?,
            )
        }
        "teale_pin_status" => pretty(&api.call("GET", "/v1/app/pins", None).await?),
        "teale_pin_create" => pretty(
            &api.call(
                "POST",
                "/v1/app/pins/create",
                Some(json!({ "name": require_str(args, "name")? })),
            )
            .await?,
        ),
        "teale_pin_join" => pretty(
            &api.call(
                "POST",
                "/v1/app/pins/join",
                Some(json!({ "code": require_str(args, "code")? })),
            )
            .await?,
        ),
        "teale_pin_requests" => {
            let id = net_segment(api, net()).await?;
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/members"), None)
                    .await?,
            )
        }
        "teale_pin_approve" | "teale_pin_deny" => {
            let id = net_segment(api, net()).await?;
            let action = if name == "teale_pin_approve" {
                "approve"
            } else {
                "deny"
            };
            let device = path_segment(require_str(args, "device")?)?;
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
            let id = net_segment(api, net()).await?;
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/members"), None)
                    .await?,
            )
        }
        "teale_pin_rotate_code" => {
            let id = net_segment(api, net()).await?;
            pretty(
                &api.call("POST", &format!("/v1/app/pins/{id}/rotate-code"), None)
                    .await?,
            )
        }
        "teale_pin_join_code" => {
            let id = net_segment(api, net()).await?;
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/join-code"), None)
                    .await?,
            )
        }
        "teale_pin_usage" => {
            let id = net_segment(api, net()).await?;
            let by = args["by"].as_str().unwrap_or("day");
            if !matches!(by, "day" | "week" | "month") {
                bail!("`by` must be day, week or month");
            }
            pretty(
                &api.call("GET", &format!("/v1/app/pins/{id}/usage?by={by}"), None)
                    .await?,
            )
        }
        "teale_pin_leave" => {
            let id = net_segment(api, net()).await?;
            pretty(
                &api.call("POST", &format!("/v1/app/pins/{id}/leave"), None)
                    .await?,
            )
        }
        "teale_exit_offer" => {
            let on = require_bool(args, "on")?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &Value) -> Vec<String> {
        list.as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn every_mutating_tool_exists() {
        let all = names(&all_tools());
        for name in MUTATING_TOOLS {
            assert!(all.iter().any(|n| n == name), "{name} is not a tool");
        }
    }

    #[test]
    fn mutating_tools_are_hidden_without_opt_in() {
        let read_only = names(&tools(false));
        assert!(read_only.iter().any(|n| n == "teale_status"));
        assert!(read_only.iter().any(|n| n == "teale_wallet_balance"));
        for name in MUTATING_TOOLS {
            assert!(!read_only.iter().any(|n| n == name), "{name} listed");
        }
        let all = names(&tools(true));
        assert_eq!(all.len(), names(&all_tools()).len());
        assert!(all.iter().any(|n| n == "teale_wallet_send"));
    }

    #[test]
    fn mutating_calls_are_refused_without_opt_in() {
        for name in ["teale_wallet_send", "teale_supply", "teale_pin_approve"] {
            let err = check_allowed(name, false).unwrap_err().to_string();
            assert!(err.contains("--allow-mutations"), "{err}");
            assert!(check_allowed(name, true).is_ok());
        }
        assert!(check_allowed("teale_status", false).is_ok());
    }

    #[test]
    fn supply_requires_explicit_on() {
        assert!(require_bool(&json!({}), "on").is_err());
        assert!(require_bool(&json!({ "on": "false" }), "on").is_err());
        assert!(!require_bool(&json!({ "on": false }), "on").unwrap());
        assert!(require_bool(&json!({ "on": true }), "on").unwrap());
    }

    #[test]
    fn required_strings_reject_missing_and_blank() {
        assert!(require_str(&json!({}), "device").is_err());
        assert!(require_str(&json!({ "device": "  " }), "device").is_err());
        assert!(require_str(&json!({ "device": 7 }), "device").is_err());
        let args = json!({ "device": "d1" });
        assert_eq!(require_str(&args, "device").unwrap(), "d1");
    }

    #[test]
    fn path_segments_are_percent_encoded() {
        assert_eq!(path_segment("dev-1_A.b~").unwrap(), "dev-1_A.b~");
        assert_eq!(path_segment("a/b?c#d").unwrap(), "a%2Fb%3Fc%23d");
        assert_eq!(path_segment("x y").unwrap(), "x%20y");
        assert_eq!(path_segment("é").unwrap(), "%C3%A9");
        for bad in ["", ".", ".."] {
            assert!(path_segment(bad).is_err(), "{bad:?} accepted");
        }
    }

    #[test]
    fn unparseable_lines_get_parse_error() {
        let err = decode_line("{not json").unwrap_err();
        assert_eq!(err["error"]["code"], json!(-32700));
        assert_eq!(err["id"], Value::Null);
        assert_eq!(err["jsonrpc"], json!("2.0"));

        let err = decode_line("[1, 2]").unwrap_err();
        assert_eq!(err["error"]["code"], json!(-32600));

        let ok = decode_line(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).unwrap();
        assert_eq!(ok["method"], json!("ping"));
    }
}

//! `teale` — one command line for Teale: manage the local daemon (mac app
//! or Rust supply node) over its loopback API - supply, models, wallet,
//! account, peers, settings, Private Inference Networks, and exit routing.
//!
//! Autodetects the daemon: --addr / TEALE_ADDR, then the mac app on
//! 127.0.0.1:11435, then teale-node on 127.0.0.1:11437.

mod api;
mod pin_cmds;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::Value;

use api::{parse_on_off, Flavor, LocalApi};

#[derive(Parser)]
#[command(
    name = "teale",
    version,
    about = "Command line for Teale - supply, models, wallet, PINs, and exit routing"
)]
struct Args {
    /// Daemon address (host[:port] or URL). Overrides autodetection.
    /// Env: TEALE_ADDR.
    #[arg(long, global = true)]
    addr: Option<String>,

    /// Machine-readable output (raw JSON from the daemon).
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Snapshot: daemon state, loaded model, wallet, account.
    Status,
    /// Turn compute supply on or off.
    Supply {
        /// on | off
        state: String,
    },
    /// Manage models on this node.
    #[command(subcommand)]
    Models(ModelsCommand),
    /// Wallet: balance, transactions, sends.
    #[command(subcommand)]
    Wallet(WalletCommand),
    /// Account info and API keys.
    #[command(subcommand)]
    Account(AccountCommand),
    /// Connected WAN peers (mac app).
    Peers,
    /// Read or change local settings.
    #[command(subcommand)]
    Settings(SettingsCommand),
    /// Manage Private Inference Networks and exit routing.
    #[command(subcommand)]
    Pin(pin_cmds::PinCommand),
}

#[derive(Subcommand)]
enum ModelsCommand {
    /// List models the daemon reports.
    List,
    /// Load a model into the inference engine.
    Load {
        model: String,
        /// Download it first if missing.
        #[arg(long)]
        download: bool,
    },
    /// Download a model without loading it.
    Download { model: String },
    /// Unload the current model.
    Unload,
}

#[derive(Subcommand)]
enum WalletCommand {
    /// Credit balance.
    Balance,
    /// Recent transactions.
    Transactions,
    /// Send credits to a peer node.
    Send {
        amount: f64,
        peer_id: String,
        #[arg(long)]
        memo: Option<String>,
    },
}

#[derive(Subcommand)]
enum AccountCommand {
    /// Account summary (identity, plan, devices).
    Summary,
    /// List API keys.
    Keys,
}

#[derive(Subcommand)]
enum SettingsCommand {
    /// Show the daemon's current settings.
    Get,
    /// Set one key (snake_case, e.g. `wan_enabled true`).
    Set { key: String, value: String },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let api = LocalApi::connect(args.addr.as_deref(), args.json).await?;
    match args.command {
        Command::Status => status(&api).await,
        Command::Supply { state } => supply(&api, &state).await,
        Command::Models(cmd) => models(&api, cmd).await,
        Command::Wallet(cmd) => wallet(&api, cmd).await,
        Command::Account(cmd) => account(&api, cmd).await,
        Command::Peers => peers(&api).await,
        Command::Settings(cmd) => settings(&api, cmd).await,
        Command::Pin(cmd) => pin_cmds::run(&api, cmd).await,
    }
}

fn render_status(v: &Value) -> String {
    let mut out = String::new();
    let pick = |keys: &[&str]| -> Option<String> {
        keys.iter().find_map(|k| v[k].as_str().map(String::from))
    };
    if let Some(ver) = pick(&["appVersion", "app_version", "version"]) {
        out.push_str(&format!("version:  {ver}\n"));
    }
    if let Some(state) = pick(&["service_state", "engineStatus", "state"]) {
        out.push_str(&format!("state:    {state}\n"));
    }
    if let Some(model) = pick(&["loaded_model_id", "loadedModelID"]) {
        out.push_str(&format!("model:    {model}\n"));
    }
    if let Some(reason) = pick(&["state_reason"]) {
        out.push_str(&format!("detail:   {reason}\n"));
    }
    let wallet = &v["wallet"];
    if wallet.is_object() {
        let credits = wallet["credits"].as_i64().map(|c| c.to_string());
        let usd = wallet["usd"].as_str().map(String::from);
        if let Some(c) = credits {
            out.push_str(&format!("credits:  {c}\n"));
        }
        if let Some(u) = usd {
            out.push_str(&format!("usd:      {u}\n"));
        }
    }
    let account = &v["account"];
    if let Some(email) = account["email"].as_str() {
        out.push_str(&format!("account:  {email}\n"));
    }
    if out.is_empty() {
        return serde_json::to_string_pretty(v).unwrap_or_default();
    }
    out.trim_end().to_string()
}

async fn status(api: &LocalApi) -> Result<()> {
    let snapshot = api.call("GET", "/v1/app", None).await?;
    if !api.json {
        eprintln!("({} on {})", api.flavor.label(), api.base);
    }
    api.emit(&snapshot, render_status);
    Ok(())
}

async fn supply(api: &LocalApi, state: &str) -> Result<()> {
    let on = parse_on_off(state, "supply state")?;
    match api.flavor {
        Flavor::Mac => {
            let resp = api
                .call(
                    "POST",
                    "/v1/desktop/app/supply",
                    Some(serde_json::json!({ "enabled": on })),
                )
                .await?;
            api.emit_ok(&resp, if on { "supply on" } else { "supply off" });
        }
        Flavor::Node => {
            let path = if on {
                "/v1/app/service/resume"
            } else {
                "/v1/app/service/pause"
            };
            let resp = api.call("POST", path, None).await?;
            api.emit_ok(&resp, if on { "supply on" } else { "supply off" });
        }
    }
    Ok(())
}

fn render_models(v: &Value) -> String {
    let rows: Vec<&Value> = v["data"]
        .as_array()
        .or_else(|| v["models"].as_array())
        .or_else(|| v.as_array())
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    if rows.is_empty() {
        return "no models reported".to_string();
    }
    let mut out = String::new();
    for m in rows {
        let id = m["id"]
            .as_str()
            .or_else(|| m["modelId"].as_str())
            .or_else(|| m.as_str())
            .unwrap_or("?");
        let state = m["state"]
            .as_str()
            .or_else(|| m["status"].as_str())
            .unwrap_or("");
        if state.is_empty() {
            out.push_str(&format!("{id}\n"));
        } else {
            out.push_str(&format!("{id:40} {state}\n"));
        }
    }
    out.trim_end().to_string()
}

async fn models(api: &LocalApi, cmd: ModelsCommand) -> Result<()> {
    match cmd {
        ModelsCommand::List => {
            let resp = api.call("GET", "/v1/models", None).await?;
            api.emit(&resp, render_models);
        }
        ModelsCommand::Load { model, download } => {
            let resp = api
                .call(
                    "POST",
                    "/v1/app/models/load",
                    Some(serde_json::json!({
                        "model": model,
                        "download_if_needed": download,
                    })),
                )
                .await?;
            api.emit_ok(&resp, format!("loading {model}"));
        }
        ModelsCommand::Download { model } => {
            let resp = api
                .call(
                    "POST",
                    "/v1/app/models/download",
                    Some(serde_json::json!({ "model": model })),
                )
                .await?;
            api.emit_ok(&resp, format!("downloading {model}"));
        }
        ModelsCommand::Unload => {
            let resp = api.call("POST", "/v1/app/models/unload", None).await?;
            api.emit_ok(&resp, "model unloaded");
        }
    }
    Ok(())
}

fn render_wallet(v: &Value) -> String {
    if v.is_object() {
        let mut out = String::new();
        for (k, val) in v.as_object().unwrap() {
            let rendered = match val {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            out.push_str(&format!("{k:16} {rendered}\n"));
        }
        return out.trim_end().to_string();
    }
    serde_json::to_string_pretty(v).unwrap_or_default()
}

fn render_transactions(v: &Value) -> String {
    let rows: Vec<&Value> = v["transactions"]
        .as_array()
        .or_else(|| v.as_array())
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    if rows.is_empty() {
        return "no transactions".to_string();
    }
    let mut out = String::new();
    for t in rows {
        let when = t["created_at"]
            .as_str()
            .or_else(|| t["timestamp"].as_str())
            .or_else(|| t["date"].as_str())
            .unwrap_or("?");
        let amount = t["amount_credits"]
            .as_i64()
            .map(|a| a.to_string())
            .or_else(|| t["amount"].as_str().map(String::from))
            .unwrap_or_else(|| t["amount"].to_string());
        let kind = t["kind"]
            .as_str()
            .or_else(|| t["type"].as_str())
            .unwrap_or("");
        let memo = t["memo"].as_str().unwrap_or("");
        out.push_str(&format!("{when:24} {amount:>12} {kind:16} {memo}\n"));
    }
    out.trim_end().to_string()
}

async fn wallet(api: &LocalApi, cmd: WalletCommand) -> Result<()> {
    match cmd {
        WalletCommand::Balance => {
            let resp = api.call("GET", "/v1/app/wallet", None).await?;
            api.emit(&resp, render_wallet);
        }
        WalletCommand::Transactions => {
            let resp = api.call("GET", "/v1/app/wallet/transactions", None).await?;
            api.emit(&resp, render_transactions);
        }
        WalletCommand::Send {
            amount,
            peer_id,
            memo,
        } => {
            if amount <= 0.0 {
                anyhow::bail!("amount must be positive");
            }
            let resp = api
                .call(
                    "POST",
                    "/v1/app/wallet/send",
                    Some(serde_json::json!({
                        "amount": amount,
                        "peer_id": peer_id,
                        "memo": memo,
                    })),
                )
                .await?;
            api.emit_ok(&resp, format!("sent {amount} credits"));
        }
    }
    Ok(())
}

async fn account(api: &LocalApi, cmd: AccountCommand) -> Result<()> {
    match cmd {
        AccountCommand::Summary => {
            let path = api.flavor_route("/v1/desktop/app/account", "/v1/app/account");
            let resp = api.call("GET", path, None).await?;
            api.emit(&resp, |v| {
                serde_json::to_string_pretty(v).unwrap_or_default()
            });
        }
        AccountCommand::Keys => {
            let path = api.flavor_route(
                "/v1/desktop/app/account/api-keys",
                "/v1/app/account/api-keys",
            );
            let resp = api.call("GET", path, None).await?;
            api.emit(&resp, |v| {
                serde_json::to_string_pretty(v).unwrap_or_default()
            });
        }
    }
    Ok(())
}

fn render_peers(v: &Value) -> String {
    let rows: Vec<&Value> = v["peers"]
        .as_array()
        .or_else(|| v.as_array())
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    if rows.is_empty() {
        return "no connected peers".to_string();
    }
    let mut out = format!("{:24} {:10} {:>8}  {}\n", "PEER", "TYPE", "MS", "ID");
    for p in rows {
        let name = p["displayName"]
            .as_str()
            .or_else(|| p["display_name"].as_str())
            .unwrap_or("-");
        let ctype = p["connectionType"]
            .as_str()
            .or_else(|| p["connection_type"].as_str())
            .unwrap_or("?");
        let latency = p["latencyMs"]
            .as_i64()
            .map(|l| l.to_string())
            .unwrap_or_else(|| "-".to_string());
        let id = p["id"]
            .as_str()
            .or_else(|| p["nodeID"].as_str())
            .unwrap_or("?");
        out.push_str(&format!("{name:24} {ctype:10} {latency:>8}  {id}\n"));
    }
    out.trim_end().to_string()
}

async fn peers(api: &LocalApi) -> Result<()> {
    let resp = api.call("GET", "/v1/app/peers", None).await?;
    api.emit(&resp, render_peers);
    Ok(())
}

async fn settings(api: &LocalApi, cmd: SettingsCommand) -> Result<()> {
    match cmd {
        SettingsCommand::Get => {
            let snapshot = api.call("GET", "/v1/app", None).await?;
            let settings = if snapshot["settings"].is_object() {
                snapshot["settings"].clone()
            } else {
                snapshot
            };
            api.emit(&settings, |v| {
                serde_json::to_string_pretty(v).unwrap_or_default()
            });
        }
        SettingsCommand::Set { key, value } => {
            let parsed = if value == "true" {
                Value::Bool(true)
            } else if value == "false" {
                Value::Bool(false)
            } else if let Ok(i) = value.parse::<i64>() {
                Value::from(i)
            } else if let Ok(f) = value.parse::<f64>() {
                Value::from(f)
            } else {
                Value::String(value)
            };
            let resp = api
                .call(
                    "PATCH",
                    "/v1/app/settings",
                    Some(serde_json::json!({ key: parsed })),
                )
                .await?;
            api.emit_ok(&resp, "setting updated");
        }
    }
    Ok(())
}

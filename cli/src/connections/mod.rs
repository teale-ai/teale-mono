//! Reversible, opt-in agent configuration. No daemon, API call or paid inference.
mod document;
mod transaction;

use anyhow::{bail, Context, Result};
use clap::{Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum Harness {
    #[value(name = "opencode")]
    OpenCode,
    Hermes,
    ClaudeCode,
    Codex,
}
impl Harness {
    fn id(self) -> &'static str {
        match self {
            Self::OpenCode => "opencode",
            Self::Hermes => "hermes",
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
        }
    }
}

#[derive(Subcommand)]
pub enum ConnectionsCommand {
    /// Inspect supported harnesses and owned receipts. Never prints credentials.
    List,
    /// Add a Teale provider. The default model changes only with --set-model.
    Add {
        #[arg(value_enum)]
        harness: Harness,
        /// Model metadata JSON (id/name/contextWindow/maxOutputTokens/vision/tools/reasoningEfforts).
        #[arg(long)]
        model_file: PathBuf,
        /// Explicit destination file. Otherwise honors harness config environment variables.
        #[arg(long)]
        config: Option<PathBuf>,
        /// Explicit Teale endpoint; HTTP accepted only on loopback.
        #[arg(long, default_value = "https://gateway.teale.com/v1")]
        base_url: String,
        /// Read the key from this environment variable; it is never accepted on the command line.
        #[arg(long, default_value = "TEALE_API_KEY")]
        key_env: String,
        #[arg(long)]
        set_model: bool,
    },
    /// Restore the exact pre-connection file only if nobody edited it. Conflicts preserve all files.
    Remove {
        #[arg(value_enum)]
        harness: Harness,
    },
    /// Roll back an interrupted transaction, refusing to overwrite later edits.
    Recover,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Model {
    id: String,
    name: String,
    context_window: u64,
    max_output_tokens: u64,
    #[serde(default)]
    vision: bool,
    #[serde(default)]
    tools: bool,
    #[serde(default)]
    reasoning_efforts: Vec<String>,
}
impl Model {
    fn validate(&self) -> Result<()> {
        if self.id.is_empty()
            || self.name.is_empty()
            || self.id.chars().any(char::is_control)
            || self.context_window == 0
            || self.max_output_tokens == 0
            || self.max_output_tokens > self.context_window
        {
            bail!("invalid model identity or token limits");
        }
        for effort in &self.reasoning_efforts {
            if !["none", "low", "medium", "high"].contains(&effort.as_str()) {
                bail!("unsupported reasoning effort");
            }
        }
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
struct Receipt {
    version: u32,
    harness: Harness,
    change: transaction::Change,
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .context("home directory unavailable")
}
fn root(home: &Path) -> PathBuf {
    home.join(".teale/connections")
}
fn config_path(home: &Path, harness: Harness) -> Result<PathBuf> {
    match harness {
        Harness::OpenCode => {
            if let Some(path) = std::env::var_os("OPENCODE_CONFIG") {
                return Ok(PathBuf::from(path));
            }
            let base = std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".config"))
                .join("opencode");
            // Do not guess between layered configurations. Ask for an explicit target.
            let candidates: Vec<_> = ["config.json", "opencode.json", "opencode.jsonc"]
                .iter()
                .map(|name| base.join(name))
                .filter(|path| path.exists())
                .collect();
            match candidates.len() {
                0 => Ok(base.join("opencode.json")),
                1 => Ok(candidates[0].clone()),
                _ => bail!("multiple OpenCode config files found; pass --config after reviewing precedence"),
            }
        }
        Harness::ClaudeCode => Ok(std::env::var_os("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"))
            .join("settings.json")),
        Harness::Codex => Ok(std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"))
            .join("config.toml")),
        Harness::Hermes => Ok(std::env::var_os("HERMES_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".hermes"))
            .join("config.yaml")),
    }
}
fn absolute(path: PathBuf) -> Result<PathBuf> {
    let path = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()?.join(path)
    };
    if path
        .components()
        .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        bail!("parent traversal in config path is not allowed");
    }
    Ok(path)
}
fn endpoint(value: &str) -> Result<String> {
    let url = reqwest::Url::parse(value).context("invalid base URL")?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        bail!("base URL must not contain credentials, query or fragment");
    }
    let local = matches!(
        url.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
    );
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        bail!("HTTPS required except loopback");
    }
    Ok(value.trim_end_matches('/').to_owned())
}

fn edits(
    harness: Harness,
    model: &Model,
    url: &str,
    key: &str,
    select: bool,
) -> Vec<(Vec<String>, Value)> {
    let path = |parts: &[&str]| parts.iter().map(|s| s.to_string()).collect();
    match harness {
        Harness::OpenCode => {
            let variants = model
                .reasoning_efforts
                .iter()
                .map(|effort| (effort.clone(), json!({"reasoningEffort": effort})))
                .collect::<serde_json::Map<_, _>>();
            let mut result = vec![(
                path(&["provider", "teale"]),
                json!({
                    "npm": "@ai-sdk/openai-compatible", "name": "Teale",
                    "options": {"baseURL": url, "apiKey": key},
                    "models": { &model.id: {"name": model.name,
                        "limit": {"context": model.context_window, "output": model.max_output_tokens},
                        "modalities": {"input": if model.vision {vec!["text", "image"]} else {vec!["text"]}, "output": ["text"]},
                        "tool_call": model.tools, "variants": variants }}
                }),
            )];
            if select {
                result.push((path(&["model"]), json!(format!("teale/{}", model.id))));
            }
            result
        }
        Harness::ClaudeCode => vec![
            (
                path(&["env", "ANTHROPIC_BASE_URL"]),
                json!(url.trim_end_matches("/v1")),
            ),
            (path(&["env", "ANTHROPIC_AUTH_TOKEN"]), json!(key)),
            (
                path(&["env", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"]),
                json!("1"),
            ),
            (path(&["model"]), json!(model.id)),
        ],
        Harness::Codex => unreachable!("Codex uses a native TOML projection"),
        Harness::Hermes => {
            let mut result = vec![(
                path(&["providers", "teale"]),
                json!({
                    "name": "Teale", "base_url": url, "api_key": key, "transport": "chat_completions"
                }),
            )];
            if select {
                result.push((path(&["model", "provider"]), json!("custom:teale")));
                result.push((path(&["model", "default"]), json!(model.id)));
            }
            // Hermes does not expose capability metadata on custom providers. Do not
            // invent support or override existing per-model reasoning preferences.
            result
        }
    }
}

pub fn run(command: ConnectionsCommand, json_output: bool) -> Result<()> {
    if !cfg!(unix) {
        bail!("connector writes require Unix file permissions; Windows ACL support is not implemented");
    }
    let home = home()?;
    let state = root(&home);
    let _lock = transaction::lock(&state)?;
    match command {
        ConnectionsCommand::List => {
            let receipts = [
                Harness::OpenCode,
                Harness::Hermes,
                Harness::ClaudeCode,
                Harness::Codex,
            ]
            .iter()
            .map(|h| {
                json!({
                    "harness": h.id(), "connected": state.join(format!("{}.json", h.id())).exists()
                })
            })
            .collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({"connections": receipts,
                "recoveryPending": state.join("journal.json").exists()}))?
            );
        }
        ConnectionsCommand::Recover => {
            transaction::recover(&state)?;
            emit(json_output, "recovered");
        }
        ConnectionsCommand::Add {
            harness,
            model_file,
            config,
            base_url,
            key_env,
            set_model,
        } => {
            transaction::require_clean(&state)?;
            if matches!(harness, Harness::ClaudeCode) && !set_model {
                bail!("Claude Code has one gateway route; --set-model is required to explicitly switch routing and model");
            }
            if key_env.is_empty()
                || !key_env
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_')
            {
                bail!("invalid key environment variable name");
            }
            let receipt_path = state.join(format!("{}.json", harness.id()));
            if receipt_path.exists() {
                bail!("already connected; remove first (later user edits are never overwritten)");
            }
            let model: Model = serde_json::from_slice(&std::fs::read(model_file)?)
                .context("invalid model metadata")?;
            model.validate()?;
            let url = endpoint(&base_url)?;
            let key = std::env::var(&key_env).context("key environment variable is not set")?;
            if key.trim().is_empty() || key.chars().any(char::is_control) {
                bail!("invalid API key");
            }
            let config = absolute(match config {
                Some(p) => p,
                None => config_path(&home, harness)?,
            })?;
            if config.starts_with(&state) {
                bail!("config cannot be inside connector state directory");
            }
            let before = transaction::read(&config)?;
            let source = before
                .as_deref()
                .unwrap_or(if matches!(harness, Harness::Codex) {
                    ""
                } else {
                    "{}\n"
                });
            let next = if matches!(harness, Harness::Codex) {
                document::codex(source, &model, &url, &key_env, set_model)?
            } else {
                document::project(
                    harness,
                    source,
                    &edits(harness, &model, &url, &key, set_model),
                )?
            };
            let change = transaction::Change {
                path: config,
                before,
                after: Some(next),
            };
            let receipt = serde_json::to_string_pretty(&Receipt {
                version: 1,
                harness,
                change: change.clone(),
            })?;
            transaction::apply(
                &state,
                vec![
                    change,
                    transaction::Change {
                        path: receipt_path,
                        before: None,
                        after: Some(receipt),
                    },
                ],
            )?;
            emit(json_output, "connected");
        }
        ConnectionsCommand::Remove { harness } => {
            transaction::require_clean(&state)?;
            let path = state.join(format!("{}.json", harness.id()));
            let source = transaction::read(&path)?.context("not connected")?;
            let receipt: Receipt =
                serde_json::from_str(&source).context("invalid connection receipt")?;
            if receipt.version != 1 || receipt.harness.id() != harness.id() {
                bail!("invalid receipt version or harness");
            }
            transaction::apply(
                &state,
                vec![
                    transaction::Change {
                        path: receipt.change.path,
                        before: receipt.change.after,
                        after: receipt.change.before,
                    },
                    transaction::Change {
                        path,
                        before: Some(source),
                        after: None,
                    },
                ],
            )?;
            emit(json_output, "disconnected");
        }
    }
    Ok(())
}
fn emit(json_output: bool, status: &str) {
    if json_output {
        println!("{}", json!({"status": status}));
    } else {
        println!("{status}; no inference was called");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn model() -> Model {
        Model {
            id: "qwen/qwen3.6-35b-a3b".into(),
            name: "Qwen".into(),
            context_window: 32768,
            max_output_tokens: 8192,
            vision: false,
            tools: true,
            reasoning_efforts: vec!["none".into(), "high".into()],
        }
    }
    #[test]
    fn model_capabilities_and_explicit_selection() {
        let m = model();
        m.validate().unwrap();
        let projected = edits(
            Harness::OpenCode,
            &m,
            "https://gateway.teale.com/v1",
            "fake-test-key",
            false,
        );
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0].1["models"][&m.id]["limit"]["context"], 32768);
        assert_eq!(projected[0].1["models"][&m.id]["tool_call"], true);
        assert_eq!(
            projected[0].1["models"][&m.id]["modalities"]["input"],
            json!(["text"])
        );
        assert_eq!(
            edits(
                Harness::OpenCode,
                &m,
                "https://gateway.teale.com/v1",
                "fake",
                true
            )
            .len(),
            2
        );
        assert_eq!(
            edits(
                Harness::Hermes,
                &m,
                "https://gateway.teale.com/v1",
                "fake",
                false
            )
            .len(),
            1
        );
    }
    #[test]
    fn endpoint_and_model_validation() {
        assert!(endpoint("http://evil.example/v1").is_err());
        assert!(endpoint("https://user:pass@example.com/v1").is_err());
        assert!(endpoint("https://example.com/v1?key=x").is_err());
        assert!(endpoint("http://127.0.0.1:11435/v1").is_ok());
        let mut m = model();
        m.max_output_tokens = 40000;
        assert!(m.validate().is_err());
    }
}

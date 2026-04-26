use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;

use teale_protocol::openai::ChatCompletionRequest;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyFilterMode {
    Off,
    #[default]
    AutoWan,
    Always,
}

impl PrivacyFilterMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::AutoWan => "auto_wan",
            Self::Always => "always",
        }
    }

    pub fn filters_remote(self) -> bool {
        !matches!(self, Self::Off)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrivacyHelperState {
    Disabled,
    Unsupported,
    Ready,
    Unavailable,
}

impl PrivacyHelperState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Unsupported => "unsupported",
            Self::Ready => "ready",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone)]
pub struct PrivacyHelperStatus {
    pub state: PrivacyHelperState,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PrivacyFilterSnapshot {
    pub mode: String,
    pub helper_status: String,
    pub helper_detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct PreparedPrivacyRequest {
    pub request: ChatCompletionRequest,
    pub placeholder_map: HashMap<String, String>,
}

impl PreparedPrivacyRequest {
    pub fn is_filtered(&self) -> bool {
        !self.placeholder_map.is_empty()
    }

    pub fn streaming_restorer(&self) -> Option<StreamingPlaceholderRestorer> {
        self.is_filtered()
            .then(|| StreamingPlaceholderRestorer::new(self.placeholder_map.clone()))
    }
}

#[derive(Debug, Clone)]
pub struct StreamingPlaceholderRestorer {
    replacements: Vec<(String, String)>,
    placeholders: Vec<String>,
    max_placeholder_len: usize,
    buffer: String,
}

impl StreamingPlaceholderRestorer {
    pub fn new(placeholder_map: HashMap<String, String>) -> Self {
        let mut replacements: Vec<_> = placeholder_map.into_iter().collect();
        replacements.sort_by(|lhs, rhs| rhs.0.len().cmp(&lhs.0.len()));
        let placeholders = replacements.iter().map(|(key, _)| key.clone()).collect::<Vec<_>>();
        let max_placeholder_len = placeholders.iter().map(|value| value.len()).max().unwrap_or(0);
        Self {
            replacements,
            placeholders,
            max_placeholder_len,
            buffer: String::new(),
        }
    }

    pub fn consume(&mut self, text: &str, terminal: bool) -> String {
        self.buffer.push_str(text);
        let holdback = if terminal {
            0
        } else {
            self.holdback_length(&self.buffer)
        };
        let safe_len = self.buffer.len().saturating_sub(holdback);
        let safe = self.buffer[..safe_len].to_string();
        self.buffer = self.buffer[safe_len..].to_string();
        self.restore_text(&safe)
    }

    pub fn finish(&mut self) -> String {
        let flushed = self.restore_text(&self.buffer);
        self.buffer.clear();
        flushed
    }

    fn restore_text(&self, text: &str) -> String {
        let mut restored = text.to_string();
        for (placeholder, original) in &self.replacements {
            restored = restored.replace(placeholder, original);
        }
        restored
    }

    fn holdback_length(&self, text: &str) -> usize {
        if self.max_placeholder_len <= 1 || text.is_empty() {
            return 0;
        }
        let max_candidate = (self.max_placeholder_len - 1).min(text.len());
        for candidate in (1..=max_candidate).rev() {
            let suffix = &text[text.len() - candidate..];
            if self
                .placeholders
                .iter()
                .any(|placeholder| placeholder.starts_with(suffix))
            {
                return candidate;
            }
        }
        0
    }
}

#[derive(Debug, Deserialize)]
struct HelperHealthResponse {
    ready: bool,
    error: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct PrivacyDetectedSpan {
    pub label: String,
    pub start: usize,
    pub end: usize,
    pub text: String,
}

#[derive(Debug, Deserialize)]
struct HelperRedactResponse {
    ok: bool,
    spans: Vec<PrivacyDetectedSpan>,
}

#[derive(Debug, Default)]
struct PlaceholderPlanner {
    placeholder_by_semantic_key: HashMap<String, String>,
    placeholder_map: HashMap<String, String>,
    next_index_by_prefix: HashMap<String, usize>,
}

impl PlaceholderPlanner {
    fn replace_spans(&mut self, text: &str, spans: &[PrivacyDetectedSpan]) -> String {
        let mut sorted = spans.to_vec();
        sorted.sort_by_key(|span| (span.start, span.end));

        let mut result = String::new();
        let mut cursor = 0usize;
        for span in sorted {
            if span.start < cursor || span.end < span.start {
                continue;
            }
            let Some(start_byte) = char_offset_to_byte_index(text, span.start) else {
                continue;
            };
            let Some(end_byte) = char_offset_to_byte_index(text, span.end) else {
                continue;
            };
            let Some(cursor_byte) = char_offset_to_byte_index(text, cursor) else {
                continue;
            };
            if start_byte < cursor_byte || end_byte < start_byte {
                continue;
            }

            result.push_str(&text[cursor_byte..start_byte]);
            let semantic_key = format!("{}\u{1f}{}", span.label, span.text);
            let placeholder = if let Some(existing) = self.placeholder_by_semantic_key.get(&semantic_key) {
                existing.clone()
            } else {
                let prefix = placeholder_prefix(&span.label);
                let next = self.next_index_by_prefix.entry(prefix.clone()).or_insert(0);
                *next += 1;
                let placeholder = format!("<{}_{}>", prefix, *next);
                self.placeholder_by_semantic_key
                    .insert(semantic_key, placeholder.clone());
                self.placeholder_map
                    .insert(placeholder.clone(), span.text.clone());
                placeholder
            };
            result.push_str(&placeholder);
            cursor = span.end;
        }

        if let Some(cursor_byte) = char_offset_to_byte_index(text, cursor) {
            result.push_str(&text[cursor_byte..]);
        }
        result
    }
}

fn char_offset_to_byte_index(text: &str, offset: usize) -> Option<usize> {
    if offset == text.chars().count() {
        return Some(text.len());
    }
    text.char_indices().nth(offset).map(|(idx, _)| idx)
}

fn placeholder_prefix(label: &str) -> String {
    match label {
        "private_person" => "PRIVATE_PERSON".to_string(),
        "private_email" => "PRIVATE_EMAIL".to_string(),
        "private_phone" => "PRIVATE_PHONE".to_string(),
        "private_date" => "PRIVATE_DATE".to_string(),
        "private_url" => "PRIVATE_URL".to_string(),
        "private_address" => "PRIVATE_ADDRESS".to_string(),
        "account_number" => "PRIVATE_ACCOUNT_NUMBER".to_string(),
        "secret" => "SECRET".to_string(),
        _ => {
            let normalized = label
                .to_ascii_uppercase()
                .replace('-', "_")
                .replace(' ', "_");
            if normalized.is_empty() {
                "REDACTED".to_string()
            } else {
                normalized
            }
        }
    }
}

#[derive(Debug)]
struct PrivacyServiceInner {
    helper_status: PrivacyHelperStatus,
    helper_process: Option<Child>,
    last_spawn_attempt: Option<Instant>,
}

impl Default for PrivacyServiceInner {
    fn default() -> Self {
        Self {
            helper_status: PrivacyHelperStatus {
                state: PrivacyHelperState::Disabled,
                detail: Some("Privacy filtering is off.".to_string()),
            },
            helper_process: None,
            last_spawn_attempt: None,
        }
    }
}

#[derive(Clone)]
pub struct PrivacyFilterService {
    client: Client,
    inner: Arc<Mutex<PrivacyServiceInner>>,
}

impl PrivacyFilterService {
    pub fn new() -> anyhow::Result<Self> {
        let client = Client::builder()
            .build()
            .context("build privacy filter helper client")?;
        Ok(Self {
            client,
            inner: Arc::new(Mutex::new(PrivacyServiceInner::default())),
        })
    }

    pub async fn snapshot(&self, mode: PrivacyFilterMode) -> PrivacyFilterSnapshot {
        let helper = self.status(mode).await;
        PrivacyFilterSnapshot {
            mode: mode.as_str().to_string(),
            helper_status: helper.state.as_str().to_string(),
            helper_detail: helper.detail,
        }
    }

    pub async fn status(&self, mode: PrivacyFilterMode) -> PrivacyHelperStatus {
        if !mode.filters_remote() {
            let status = PrivacyHelperStatus {
                state: PrivacyHelperState::Disabled,
                detail: Some("Privacy filtering is off.".to_string()),
            };
            self.inner.lock().await.helper_status = status.clone();
            return status;
        }

        match self.ensure_helper_available().await {
            Ok(()) => {
                let status = PrivacyHelperStatus {
                    state: PrivacyHelperState::Ready,
                    detail: Some("Helper is ready.".to_string()),
                };
                self.inner.lock().await.helper_status = status.clone();
                status
            }
            Err(error) => {
                let state = if self.is_supported_platform() {
                    PrivacyHelperState::Unavailable
                } else {
                    PrivacyHelperState::Unsupported
                };
                let status = PrivacyHelperStatus {
                    state,
                    detail: Some(error.to_string()),
                };
                self.inner.lock().await.helper_status = status.clone();
                status
            }
        }
    }

    pub async fn prepare_request(
        &self,
        request: ChatCompletionRequest,
        mode: PrivacyFilterMode,
    ) -> anyhow::Result<PreparedPrivacyRequest> {
        if !mode.filters_remote() {
            return Ok(PreparedPrivacyRequest {
                request,
                placeholder_map: HashMap::new(),
            });
        }

        self.ensure_supported_request(&request)?;
        self.ensure_helper_available().await?;

        let mut filtered = request;
        let mut planner = PlaceholderPlanner::default();

        for message in &mut filtered.messages {
            let Some(content) = message.content.as_str() else {
                bail!("privacy filtering currently supports only string message content");
            };
            if content.is_empty() {
                continue;
            }
            let spans = self.redact_spans(content).await?;
            if spans.is_empty() {
                continue;
            }
            message.content = Value::String(planner.replace_spans(content, &spans));
        }

        Ok(PreparedPrivacyRequest {
            request: filtered,
            placeholder_map: planner.placeholder_map,
        })
    }

    fn ensure_supported_request(&self, request: &ChatCompletionRequest) -> anyhow::Result<()> {
        if request.tools.as_ref().is_some_and(|value| !value.is_null()) {
            bail!("privacy filtering currently does not support tool-enabled remote chat");
        }
        if request.tool_choice.as_ref().is_some_and(|value| !value.is_null()) {
            bail!("privacy filtering currently does not support tool-enabled remote chat");
        }
        if request
            .response_format
            .as_ref()
            .is_some_and(|value| !value.is_null())
        {
            bail!("privacy filtering currently supports only plain text remote chat");
        }
        for message in &request.messages {
            if message.tool_calls.as_ref().is_some_and(|value| !value.is_null())
                || message.tool_call_id.as_ref().is_some()
            {
                bail!("privacy filtering currently does not support tool call messages");
            }
            if !message.content.is_string() {
                bail!("privacy filtering currently supports only string message content");
            }
        }
        Ok(())
    }

    fn is_supported_platform(&self) -> bool {
        std::env::var("TEALE_OPF_HELPER_URL").is_ok()
            || locate_helper_script().is_ok()
            || cfg!(windows)
    }

    async fn ensure_helper_available(&self) -> anyhow::Result<()> {
        if self.ping_health().await.is_ok() {
            return Ok(());
        }

        if std::env::var("TEALE_OPF_HELPER_URL").is_err() {
            self.spawn_helper_if_needed().await?;
            for _ in 0..12 {
                tokio::time::sleep(Duration::from_millis(250)).await;
                if self.ping_health().await.is_ok() {
                    return Ok(());
                }
            }
        }

        let detail = self
            .inner
            .lock()
            .await
            .helper_status
            .detail
            .clone()
            .unwrap_or_else(|| "helper did not become ready".to_string());
        bail!("{detail}");
    }

    async fn ping_health(&self) -> anyhow::Result<()> {
        let url = format!("{}/health", helper_base_url().trim_end_matches('/'));
        let response = self
            .client
            .get(&url)
            .timeout(Duration::from_millis(1500))
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        if !status.is_success() {
            let detail = if text.is_empty() {
                format!("HTTP {status}")
            } else {
                text
            };
            self.inner.lock().await.helper_status = PrivacyHelperStatus {
                state: PrivacyHelperState::Unavailable,
                detail: Some(detail.clone()),
            };
            bail!("{detail}");
        }
        let health: HelperHealthResponse =
            serde_json::from_str(&text).context("decode privacy helper health")?;
        if !health.ready {
            let detail = health
                .error
                .unwrap_or_else(|| "helper reported not ready".to_string());
            self.inner.lock().await.helper_status = PrivacyHelperStatus {
                state: PrivacyHelperState::Unavailable,
                detail: Some(detail.clone()),
            };
            bail!("{detail}");
        }
        Ok(())
    }

    async fn redact_spans(&self, text: &str) -> anyhow::Result<Vec<PrivacyDetectedSpan>> {
        let url = format!("{}/v1/redact", helper_base_url().trim_end_matches('/'));
        let response = self
            .client
            .post(&url)
            .timeout(Duration::from_secs(30))
            .json(&json!({ "text": text }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            bail!(
                "{}",
                if body.is_empty() {
                    format!("privacy helper returned HTTP {status}")
                } else {
                    body
                }
            );
        }
        let payload: HelperRedactResponse =
            serde_json::from_str(&body).context("decode privacy helper redact response")?;
        if !payload.ok {
            bail!("privacy helper reported an unsuccessful redact response");
        }
        Ok(payload.spans)
    }

    async fn spawn_helper_if_needed(&self) -> anyhow::Result<()> {
        let mut inner = self.inner.lock().await;
        if let Some(child) = inner.helper_process.as_mut() {
            if child.try_wait()?.is_none() {
                return Ok(());
            }
        }

        if let Some(last_attempt) = inner.last_spawn_attempt {
            if last_attempt.elapsed() < Duration::from_secs(2) {
                return Ok(());
            }
        }
        inner.last_spawn_attempt = Some(Instant::now());

        let script = locate_helper_script()?;
        let mut command = helper_command(script);
        command.stdout(Stdio::null()).stderr(Stdio::null());
        let child = command.spawn().context("spawn privacy filter helper")?;
        inner.helper_process = Some(child);
        Ok(())
    }
}

fn helper_base_url() -> String {
    std::env::var("TEALE_OPF_HELPER_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:11439".to_string())
}

fn locate_helper_script() -> anyhow::Result<PathBuf> {
    if let Ok(path) = std::env::var("TEALE_OPF_HELPER_SCRIPT") {
        let candidate = PathBuf::from(path);
        if candidate.exists() {
            return Ok(candidate);
        }
    }

    for root in candidate_roots() {
        let candidate = root.join("scripts").join("privacy_filter_helper.py");
        if candidate.exists() {
            return Ok(candidate);
        }
    }

    Err(anyhow!(
        "scripts/privacy_filter_helper.py was not found"
    ))
}

fn candidate_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        let mut current = cwd.clone();
        roots.push(cwd);
        for _ in 0..8 {
            if let Some(parent) = current.parent() {
                roots.push(parent.to_path_buf());
                current = parent.to_path_buf();
            } else {
                break;
            }
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        let mut current = exe.parent().map(PathBuf::from);
        for _ in 0..8 {
            let Some(dir) = current.take() else {
                break;
            };
            roots.push(dir.clone());
            current = dir.parent().map(PathBuf::from);
        }
    }
    roots
}

fn helper_command(script: PathBuf) -> Command {
    if let Ok(interpreter) = std::env::var("TEALE_OPF_HELPER_PYTHON") {
        let mut command = Command::new(interpreter);
        command
            .arg(script)
            .arg("--host")
            .arg("127.0.0.1")
            .arg("--port")
            .arg("11439")
            .arg("--device")
            .arg("cpu");
        return command;
    }

    #[cfg(windows)]
    {
        if which::which("py").is_ok() {
            let mut command = Command::new("py");
            command
                .arg("-3")
                .arg(script)
                .arg("--host")
                .arg("127.0.0.1")
                .arg("--port")
                .arg("11439")
                .arg("--device")
                .arg("cpu");
            return command;
        }
    }

    let python = if which::which("python3").is_ok() {
        "python3"
    } else {
        "python"
    };
    let mut command = Command::new(python);
    command
        .arg(script)
        .arg("--host")
        .arg("127.0.0.1")
        .arg("--port")
        .arg("11439")
        .arg("--device")
        .arg("cpu");
    command
}

#[cfg(test)]
mod tests {
    use super::{PlaceholderPlanner, PrivacyDetectedSpan, StreamingPlaceholderRestorer};
    use std::collections::HashMap;

    #[test]
    fn placeholder_planner_reuses_same_label_and_text() {
        let mut planner = PlaceholderPlanner::default();
        let redacted = planner.replace_spans(
            "Taylor emailed taylor@example.com and Taylor replied.",
            &[
                PrivacyDetectedSpan {
                    label: "private_person".to_string(),
                    start: 0,
                    end: 6,
                    text: "Taylor".to_string(),
                },
                PrivacyDetectedSpan {
                    label: "private_email".to_string(),
                    start: 15,
                    end: 33,
                    text: "taylor@example.com".to_string(),
                },
                PrivacyDetectedSpan {
                    label: "private_person".to_string(),
                    start: 38,
                    end: 44,
                    text: "Taylor".to_string(),
                },
            ],
        );

        assert_eq!(
            redacted,
            "<PRIVATE_PERSON_1> emailed <PRIVATE_EMAIL_1> and <PRIVATE_PERSON_1> replied."
        );
        assert_eq!(planner.placeholder_map["<PRIVATE_PERSON_1>"], "Taylor");
        assert_eq!(
            planner.placeholder_map["<PRIVATE_EMAIL_1>"],
            "taylor@example.com"
        );
    }

    #[test]
    fn streaming_restorer_handles_split_placeholder() {
        let mut map = HashMap::new();
        map.insert("<PRIVATE_PERSON_1>".to_string(), "Taylor".to_string());
        let mut restorer = StreamingPlaceholderRestorer::new(map);

        assert_eq!(restorer.consume("Hello <PRIV", false), "Hello ");
        assert_eq!(restorer.consume("ATE_PERSON_1>.", false), "Taylor.");
        assert_eq!(restorer.finish(), "");
    }

    #[test]
    fn streaming_restorer_does_not_restore_transformed_placeholder() {
        let mut map = HashMap::new();
        map.insert("<PRIVATE_EMAIL_1>".to_string(), "taylor@example.com".to_string());
        let mut restorer = StreamingPlaceholderRestorer::new(map);

        assert_eq!(
            restorer.consume("<private_email_1>", false),
            "<private_email_1>"
        );
        assert_eq!(restorer.finish(), "");
    }
}

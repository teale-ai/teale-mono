//! Durable PIN usage accounting (token COUNTS only — never credits).
//!
//! Provider devices record one entry per completed request into a
//! disk-backed queue, flushed to the gateway every 60 s or 50 records.
//! Batches carry a UUID `batchId`; the gateway dedups replays, so the
//! crash-safety story is at-least-once send + server-side idempotency:
//!   records.jsonl  — appended per request, truncated when batched
//!   outbox/<batchId>.json — batches awaiting a 2xx, deleted on success

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

pub const FLUSH_INTERVAL_SECONDS: u64 = 60;
pub const FLUSH_THRESHOLD: usize = 50;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageRecord {
    pub pin_id: String,
    /// YYYY-MM-DD (UTC).
    pub day: String,
    pub consumer_device_id: String,
    pub model_id: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    /// Exit-bandwidth metering (#171): present only on records whose
    /// model_id is `__exit__`. Older gateways ignore unknown fields.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes_in: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes_out: Option<i64>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Batch {
    pin_id: String,
    batch_id: String,
    entries: Vec<BatchEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BatchEntry {
    day: String,
    consumer_device_id: String,
    model_id: String,
    requests: i64,
    tokens_in: i64,
    tokens_out: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bytes_in: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bytes_out: Option<i64>,
}

pub struct UsageBatcher {
    dir: PathBuf,
    /// Guards records.jsonl + the in-memory count.
    inner: Mutex<usize>,
}

pub fn today_utc() -> String {
    // Days bucket usage; civil-date math from the unix epoch.
    let secs = crate::gateway_wallet::now_unix_secs() as i64;
    let days = secs.div_euclid(86_400);
    civil_from_days(days)
}

/// Howard Hinnant's days→civil algorithm.
fn civil_from_days(z: i64) -> String {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

impl UsageBatcher {
    pub fn new(dir: PathBuf) -> Result<Arc<Self>> {
        std::fs::create_dir_all(dir.join("outbox")).context("create usage outbox")?;
        let count = std::fs::read_to_string(dir.join("records.jsonl"))
            .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count())
            .unwrap_or(0);
        Ok(Arc::new(Self {
            dir,
            inner: Mutex::new(count),
        }))
    }

    /// Append one completed-request record. Returns true when the caller
    /// should trigger a flush (threshold reached).
    pub fn record(&self, record: &UsageRecord) -> Result<bool> {
        use std::io::Write;
        let mut count = self.inner.lock();
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("records.jsonl"))?;
        writeln!(file, "{}", serde_json::to_string(record)?)?;
        *count += 1;
        Ok(*count >= FLUSH_THRESHOLD)
    }

    /// Move pending records into per-network batch files in the outbox.
    fn seal_batches(&self) -> Result<()> {
        let mut count = self.inner.lock();
        let path = self.dir.join("records.jsonl");
        let Ok(contents) = std::fs::read_to_string(&path) else {
            return Ok(());
        };
        let records: Vec<UsageRecord> = contents
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        if records.is_empty() {
            return Ok(());
        }
        // Aggregate per (pin, day, consumer, model) within the batch.
        let mut by_pin: std::collections::HashMap<
            String,
            std::collections::HashMap<(String, String, String), BatchEntry>,
        > = std::collections::HashMap::new();
        for r in records {
            let entry = by_pin
                .entry(r.pin_id.clone())
                .or_default()
                .entry((
                    r.day.clone(),
                    r.consumer_device_id.clone(),
                    r.model_id.clone(),
                ))
                .or_insert_with(|| BatchEntry {
                    day: r.day,
                    consumer_device_id: r.consumer_device_id,
                    model_id: r.model_id,
                    requests: 0,
                    tokens_in: 0,
                    tokens_out: 0,
                    bytes_in: None,
                    bytes_out: None,
                });
            entry.requests += 1;
            entry.tokens_in += r.tokens_in;
            entry.tokens_out += r.tokens_out;
            if let Some(b) = r.bytes_in {
                *entry.bytes_in.get_or_insert(0) += b;
            }
            if let Some(b) = r.bytes_out {
                *entry.bytes_out.get_or_insert(0) += b;
            }
        }
        for (pin_id, entries) in by_pin {
            let batch = Batch {
                pin_id,
                batch_id: uuid::Uuid::new_v4().to_string(),
                entries: entries.into_values().collect(),
            };
            // Write the batch BEFORE truncating records: a crash between the
            // two duplicates counts at worst, and batchId dedup absorbs it.
            std::fs::write(
                self.dir
                    .join("outbox")
                    .join(format!("{}.json", batch.batch_id)),
                serde_json::to_vec(&batch)?,
            )?;
        }
        std::fs::write(&path, b"")?;
        *count = 0;
        Ok(())
    }

    /// Seal pending records and push every outbox batch. Batches are deleted
    /// on 2xx (including "duplicate" replays); network errors leave them for
    /// the next flush — offline periods backfill automatically.
    pub async fn flush(
        &self,
        client: &reqwest::Client,
        gateway_url: &str,
        bearer: &str,
    ) -> Result<usize> {
        self.seal_batches()?;
        let mut delivered = 0;
        let outbox = self.dir.join("outbox");
        for entry in std::fs::read_dir(&outbox)?.flatten() {
            let path = entry.path();
            let Ok(bytes) = std::fs::read(&path) else {
                continue;
            };
            let Ok(batch) = serde_json::from_slice::<Batch>(&bytes) else {
                // Unparseable leftovers would wedge the outbox forever.
                std::fs::remove_file(&path).ok();
                continue;
            };
            let response = client
                .post(format!(
                    "{gateway_url}/v1/pins/{}/usage-report",
                    batch.pin_id
                ))
                .bearer_auth(bearer)
                .json(&serde_json::json!({
                    "batchId": batch.batch_id,
                    "entries": batch.entries,
                }))
                .send()
                .await;
            match response {
                Ok(resp) if resp.status().is_success() => {
                    std::fs::remove_file(&path).ok();
                    delivered += 1;
                }
                Ok(resp) if resp.status() == reqwest::StatusCode::NOT_FOUND => {
                    // Removed from the network: this usage can never land.
                    std::fs::remove_file(&path).ok();
                }
                _ => {} // keep for retry
            }
        }
        Ok(delivered)
    }

    pub fn pending_batches(&self) -> usize {
        std::fs::read_dir(self.dir.join("outbox"))
            .map(|d| d.flatten().count())
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn record(pin: &str, tokens_out: i64) -> UsageRecord {
        UsageRecord {
            pin_id: pin.into(),
            day: "2026-07-04".into(),
            consumer_device_id: "consumer-1".into(),
            model_id: "qwen3-4b".into(),
            tokens_in: 100,
            tokens_out,
        }
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pin-usage-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Mock gateway that can be told to fail; records received batch ids.
    async fn mock_sink(
        fail: Arc<Mutex<bool>>,
        seen: Arc<Mutex<Vec<String>>>,
    ) -> std::net::SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let fail = fail.clone();
                let seen = seen.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 65536];
                    let Ok(len) = stream.read(&mut buf).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buf[..len]).to_string();
                    if *fail.lock() {
                        let _ = stream
                            .write_all(b"HTTP/1.1 503 Unavailable\r\ncontent-length: 0\r\n\r\n")
                            .await;
                        return;
                    }
                    if let Some(body_start) = request.find("\r\n\r\n") {
                        if let Ok(v) =
                            serde_json::from_str::<serde_json::Value>(&request[body_start + 4..])
                        {
                            if let Some(id) = v["batchId"].as_str() {
                                seen.lock().push(id.to_string());
                            }
                        }
                    }
                    let body = r#"{"status":"applied"}"#;
                    let _ = stream
                        .write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                                body.len(),
                                body
                            )
                            .as_bytes(),
                        )
                        .await;
                });
            }
        });
        addr
    }

    #[tokio::test]
    async fn records_flush_and_backfill_after_outage() {
        let dir = temp_dir();
        let batcher = UsageBatcher::new(dir.clone()).unwrap();
        assert!(!batcher.record(&record("pin-a", 10)).unwrap());
        batcher.record(&record("pin-a", 20)).unwrap();
        batcher.record(&record("pin-b", 5)).unwrap();

        let fail = Arc::new(Mutex::new(true));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let addr = mock_sink(fail.clone(), seen.clone()).await;
        let client = reqwest::Client::new();
        let url = format!("http://{addr}");

        // Gateway down: batches sealed but retained.
        let delivered = batcher.flush(&client, &url, "tok").await.unwrap();
        assert_eq!(delivered, 0);
        assert_eq!(batcher.pending_batches(), 2, "one batch per network");

        // Gateway back: everything backfills, outbox drains.
        *fail.lock() = false;
        let delivered = batcher.flush(&client, &url, "tok").await.unwrap();
        assert_eq!(delivered, 2);
        assert_eq!(batcher.pending_batches(), 0);
        assert_eq!(seen.lock().len(), 2);

        // Batch ids are stable across retries (aggregation happened once):
        // re-flush sends nothing new.
        let delivered = batcher.flush(&client, &url, "tok").await.unwrap();
        assert_eq!(delivered, 0);
    }

    #[tokio::test]
    async fn aggregation_within_batch() {
        let dir = temp_dir();
        let batcher = UsageBatcher::new(dir.clone()).unwrap();
        for _ in 0..3 {
            batcher.record(&record("pin-a", 7)).unwrap();
        }
        batcher.seal_batches().unwrap();
        let outbox = dir.join("outbox");
        let file = std::fs::read_dir(outbox).unwrap().flatten().next().unwrap();
        let batch: Batch = serde_json::from_slice(&std::fs::read(file.path()).unwrap()).unwrap();
        assert_eq!(batch.entries.len(), 1);
        assert_eq!(batch.entries[0].requests, 3);
        assert_eq!(batch.entries[0].tokens_out, 21);
    }

    #[test]
    fn threshold_signals_flush() {
        let dir = temp_dir();
        let batcher = UsageBatcher::new(dir).unwrap();
        for i in 0..FLUSH_THRESHOLD {
            let should_flush = batcher.record(&record("pin-a", 1)).unwrap();
            assert_eq!(should_flush, i + 1 >= FLUSH_THRESHOLD);
        }
    }

    #[test]
    fn civil_date_conversion() {
        assert_eq!(civil_from_days(0), "1970-01-01");
        assert_eq!(civil_from_days(20_274), "2025-07-05");
    }
}

//! Per-request records. Written as JSON Lines.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::time::SystemTime;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RequestRecord {
    pub ts_unix_ms: u128,
    pub run_id: String,
    pub model: String,
    pub prompt_tokens: u32,
    pub max_tokens: u32,
    pub streaming: bool,
    pub status: String,
    pub http_status: u16,
    pub ttft_ms: Option<u64>,
    pub total_ms: u64,
    pub tokens_out: Option<u32>,
    pub chosen_device: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

pub struct RecordWriter {
    inner: Mutex<BufWriter<File>>,
    run_id: String,
}

impl RecordWriter {
    pub fn new(path: &Path, run_id: String) -> anyhow::Result<Self> {
        let file = File::create(path)?;
        Ok(Self {
            inner: Mutex::new(BufWriter::new(file)),
            run_id,
        })
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn write(&self, rec: &RequestRecord) -> anyhow::Result<()> {
        let line = serde_json::to_string(rec)?;
        let mut w = self.inner.lock();
        w.write_all(line.as_bytes())?;
        w.write_all(b"\n")?;
        Ok(())
    }

    pub fn flush(&self) -> anyhow::Result<()> {
        self.inner.lock().flush()?;
        Ok(())
    }
}

pub fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

//! Provider side of the PIN exit-node data plane (#166, metering for #171):
//! accepts SOCKS5-over-Noise byte streams from fellow PIN members and
//! egresses them to the open internet. Mirrors the Mac app's
//! PINExitServer: membership is already proven by the transport handshake
//! (netmap-signed Noise), the device offers exit only when `[pin]
//! offer_exit = true`, and DNS resolves HERE on the exit - consumers send
//! hostnames, so consumer-side DNS poisoning never applies.
//!
//! Every relayed byte is metered per (pin, consumer device, day) and fed
//! into the durable usage batcher with model id `__exit__`, so exit
//! bandwidth rides the same at-least-once + server-dedup pipeline as
//! inference token counts.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use parking_lot::Mutex;
use teale_protocol::cluster::{
    SocksClosePayload, SocksDataPayload, SocksOpenPayload, SocksOpenResultPayload,
};
use teale_protocol::ClusterMessage;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{info, warn};

use super::transport::PeerConnection;
use super::usage::{today_utc, UsageBatcher, UsageRecord};

/// Model-id sentinel for exit-bandwidth usage records.
pub const EXIT_MODEL_ID: &str = "__exit__";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_BUF: usize = 16 * 1024;
/// Swift transport fragments at ~1100 bytes of plaintext; keep chunks small.
const SEND_CHUNK: usize = 1000;
const METER_FLUSH_SECONDS: u64 = 60;

/// Per-(pin, consumer, day) byte counters. Drained into the usage batcher
/// once a minute; a crash between flushes loses at most a minute of
/// metering (counts, never prompts - the privacy boundary holds).
#[derive(Default)]
pub struct ExitMeter {
    /// (pin_id, consumer_device_id, day) -> (bytes_in, bytes_out).
    inner: Mutex<HashMap<(String, String, String), (i64, i64)>>,
}

impl ExitMeter {
    fn add(&self, pin_id: &str, consumer: &str, bytes_in: i64, bytes_out: i64) {
        let mut map = self.inner.lock();
        let entry = map
            .entry((pin_id.to_string(), consumer.to_string(), today_utc()))
            .or_insert((0, 0));
        entry.0 += bytes_in;
        entry.1 += bytes_out;
    }

    /// Append one UsageRecord per accumulator and reset. Best-effort: a
    /// failed append keeps the counts for the next drain.
    fn drain_into(&self, usage: &UsageBatcher) {
        let records: Vec<((String, String, String), (i64, i64))> = {
            let mut map = self.inner.lock();
            map.drain().collect()
        };
        for ((pin_id, consumer, day), (bytes_in, bytes_out)) in records {
            let record = UsageRecord {
                pin_id,
                day,
                consumer_device_id: consumer,
                model_id: EXIT_MODEL_ID.to_string(),
                tokens_in: 0,
                tokens_out: 0,
                bytes_in: Some(bytes_in),
                bytes_out: Some(bytes_out),
            };
            if let Err(err) = usage.record(&record) {
                warn!("exit meter: failed to persist usage record: {err:#}");
                // Re-add so the bytes are not lost.
                let mut map = self.inner.lock();
                let key = (record.pin_id.clone(), record.consumer_device_id.clone(), record.day.clone());
                let entry = map.entry(key).or_insert((0, 0));
                entry.0 += bytes_in;
                entry.1 += bytes_out;
            }
        }
    }
}

struct EgressStream {
    writer: tokio::net::tcp::OwnedWriteHalf,
    last_activity: Instant,
    /// Metering attribution bound at open time.
    pin_id: String,
    consumer_device_id: String,
}

/// Exit provider: stream registry + meter + the opt-in flag.
pub struct ExitProvider {
    streams: Mutex<HashMap<String, EgressStream>>,
    meter: Arc<ExitMeter>,
}

impl ExitProvider {
    /// Build the provider and start the meter drain loop.
    pub fn new(usage: Arc<UsageBatcher>) -> Arc<Self> {
        let meter = Arc::new(ExitMeter::default());
        {
            let meter = meter.clone();
            tokio::spawn(async move {
                let mut interval =
                    tokio::time::interval(Duration::from_secs(METER_FLUSH_SECONDS));
                interval.tick().await;
                loop {
                    interval.tick().await;
                    meter.drain_into(&usage);
                }
            });
        }
        Arc::new(Self {
            streams: Mutex::new(HashMap::new()),
            meter,
        })
    }

    pub async fn handle_open(
        self: &Arc<Self>,
        connection: Arc<PeerConnection>,
        pin_id: String,
        consumer_device_id: String,
        open: SocksOpenPayload,
    ) {
        let stream_id = open.stream_id.clone();
        let result = match tokio::time::timeout(
            CONNECT_TIMEOUT,
            TcpStream::connect((open.dest_host.as_str(), open.dest_port)),
        )
        .await
        {
            Ok(Ok(stream)) => {
                let (mut reader, writer) = stream.into_split();
                self.streams.lock().insert(
                    stream_id.clone(),
                    EgressStream {
                        writer,
                        last_activity: Instant::now(),
                        pin_id: pin_id.clone(),
                        consumer_device_id: consumer_device_id.clone(),
                    },
                );
                info!(
                    "exit: {}:{} for {} via stream {} (pin {})",
                    open.dest_host, open.dest_port, consumer_device_id, stream_id, pin_id
                );
                // Pump egress -> consumer in small chunks.
                let provider = self.clone();
                let conn = connection.clone();
                let sid = stream_id.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; READ_BUF];
                    loop {
                        match reader.read(&mut buf).await {
                            Ok(0) => break,
                            Ok(n) => {
                                provider.meter.add(&pin_id, &consumer_device_id, 0, n as i64);
                                for chunk in buf[..n].chunks(SEND_CHUNK) {
                                    let msg = ClusterMessage::SocksData(SocksDataPayload {
                                        stream_id: sid.clone(),
                                        data: base64::engine::general_purpose::STANDARD
                                            .encode(chunk),
                                    });
                                    if conn.send(&msg).await.is_err() {
                                        break;
                                    }
                                }
                                if let Some(s) = provider.streams.lock().get_mut(&sid) {
                                    s.last_activity = Instant::now();
                                }
                            }
                            Err(_) => break,
                        }
                    }
                    provider.streams.lock().remove(&sid);
                    let _ = conn
                        .send(&ClusterMessage::SocksClose(SocksClosePayload {
                            stream_id: sid,
                            reason: Some("destination closed".to_string()),
                        }))
                        .await;
                });
                SocksOpenResultPayload {
                    stream_id: stream_id.clone(),
                    ok: true,
                    error: None,
                }
            }
            Ok(Err(err)) => SocksOpenResultPayload {
                stream_id: stream_id.clone(),
                ok: false,
                error: Some(format!("connect failed: {err}")),
            },
            Err(_) => SocksOpenResultPayload {
                stream_id: stream_id.clone(),
                ok: false,
                error: Some("connect timed out".to_string()),
            },
        };
        let _ = connection.send(&ClusterMessage::SocksOpenResult(result)).await;
    }

    pub async fn handle_data(&self, data: SocksDataPayload) {
        let bytes = match base64::engine::general_purpose::STANDARD.decode(&data.data) {
            Ok(b) => b,
            Err(_) => return,
        };
        let mut streams = self.streams.lock();
        if let Some(stream) = streams.get_mut(&data.stream_id) {
            if stream.writer.write_all(&bytes).await.is_ok() {
                stream.last_activity = Instant::now();
                self.meter.add(
                    &stream.pin_id,
                    &stream.consumer_device_id,
                    bytes.len() as i64,
                    0,
                );
            }
        }
    }

    pub async fn handle_close(&self, close: SocksClosePayload) {
        if let Some(mut stream) = self.streams.lock().remove(&close.stream_id) {
            let _ = stream.writer.shutdown().await;
        }
    }
}

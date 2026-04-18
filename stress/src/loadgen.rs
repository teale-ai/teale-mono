//! Async load generator hitting the gateway with OpenAI-compatible requests.

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use rand::distributions::{Distribution, WeightedIndex};
use rand::Rng;
use rand_distr::Normal;
use reqwest::Client;
use serde_json::json;
use tokio::sync::Semaphore;
use tracing::{debug, info, warn};

use crate::record::{now_ms, RecordWriter, RequestRecord};
use crate::scenario::{RequestMix, Scenario};

pub async fn run(scenario: Scenario, writer: Arc<RecordWriter>) -> anyhow::Result<Stats> {
    info!("scenario '{}' starting: {}s @ {:.2} rps", scenario.name, scenario.duration_seconds, scenario.rps);

    let client = Client::builder()
        .timeout(Duration::from_secs(600))
        .build()?;

    let weights: Vec<u32> = scenario.requests.iter().map(|r| r.weight).collect();
    let dist = WeightedIndex::new(&weights)?;

    let sem = Arc::new(Semaphore::new(scenario.concurrency_cap as usize));

    let mut stats = Stats::default();
    let stats_shared = Arc::new(parking_lot::Mutex::new(Stats::default()));

    // Warmup: send a few small probes to let the fleet wake up.
    if scenario.warmup_seconds > 0 {
        info!("warmup {}s", scenario.warmup_seconds);
        tokio::time::sleep(Duration::from_secs(scenario.warmup_seconds)).await;
    }

    let period = Duration::from_secs_f64(1.0 / scenario.rps.max(0.01));
    let mut ticker = tokio::time::interval(period);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Burst);
    let deadline = Instant::now() + Duration::from_secs(scenario.duration_seconds);

    let mut rng = rand::thread_rng();
    let mut handles = Vec::new();

    while Instant::now() < deadline {
        ticker.tick().await;

        let idx = dist.sample(&mut rng);
        let mix = scenario.requests[idx].clone();
        let permit = match sem.clone().try_acquire_owned() {
            Ok(p) => p,
            Err(_) => {
                debug!("concurrency cap reached — dropping tick");
                stats.dropped += 1;
                continue;
            }
        };

        let client_c = client.clone();
        let writer_c = writer.clone();
        let url = scenario.gateway_url.clone();
        let token = scenario.token.clone();
        let run_id = writer.run_id().to_string();
        let prompt_tokens = sample_normal_u32(&mut rng, mix.prompt_tokens_mean, mix.prompt_tokens_stddev);
        let stats_sh = stats_shared.clone();

        let handle = tokio::spawn(async move {
            let _permit = permit;
            run_one(&client_c, &url, &token, &mix, prompt_tokens, &writer_c, &run_id, &stats_sh).await;
        });
        handles.push(handle);
    }

    // Wait for all in-flight to finish before summarizing.
    for h in handles {
        let _ = h.await;
    }

    let final_stats = stats_shared.lock().clone();
    let mut out = final_stats;
    out.dropped += stats.dropped;
    writer.flush()?;
    Ok(out)
}

async fn run_one(
    client: &Client,
    gateway_url: &str,
    token: &str,
    mix: &RequestMix,
    prompt_tokens: u32,
    writer: &Arc<RecordWriter>,
    run_id: &str,
    stats: &Arc<parking_lot::Mutex<Stats>>,
) {
    let messages = build_messages(mix, prompt_tokens);
    let body = json!({
        "model": mix.model,
        "messages": messages,
        "max_tokens": mix.max_tokens,
        "stream": mix.streaming,
        "temperature": 0.7,
    });

    let started = Instant::now();
    let resp = client
        .post(format!("{}/v1/chat/completions", gateway_url.trim_end_matches('/')))
        .bearer_auth(token)
        .json(&body)
        .send()
        .await;

    let resp = match resp {
        Ok(r) => r,
        Err(e) => {
            record_and_stat(
                writer,
                stats,
                RequestRecord {
                    ts_unix_ms: now_ms(),
                    run_id: run_id.to_string(),
                    model: mix.model.clone(),
                    prompt_tokens,
                    max_tokens: mix.max_tokens,
                    streaming: mix.streaming,
                    status: "connect_error".into(),
                    http_status: 0,
                    ttft_ms: None,
                    total_ms: started.elapsed().as_millis() as u64,
                    tokens_out: None,
                    chosen_device: None,
                    error: Some(e.to_string()),
                },
            );
            return;
        }
    };

    let http_status = resp.status().as_u16();
    let chosen_device = resp
        .headers()
        .get("x-teale-device")
        .and_then(|v| v.to_str().ok())
        .map(String::from);

    if !resp.status().is_success() {
        let txt = resp.text().await.unwrap_or_default();
        record_and_stat(
            writer,
            stats,
            RequestRecord {
                ts_unix_ms: now_ms(),
                run_id: run_id.to_string(),
                model: mix.model.clone(),
                prompt_tokens,
                max_tokens: mix.max_tokens,
                streaming: mix.streaming,
                status: format!("http_{}", http_status),
                http_status,
                ttft_ms: None,
                total_ms: started.elapsed().as_millis() as u64,
                tokens_out: None,
                chosen_device,
                error: Some(txt),
            },
        );
        return;
    }

    if !mix.streaming {
        let text = resp.text().await.unwrap_or_default();
        let tokens_out = try_count_tokens(&text);
        record_and_stat(
            writer,
            stats,
            RequestRecord {
                ts_unix_ms: now_ms(),
                run_id: run_id.to_string(),
                model: mix.model.clone(),
                prompt_tokens,
                max_tokens: mix.max_tokens,
                streaming: false,
                status: "ok".into(),
                http_status,
                ttft_ms: None,
                total_ms: started.elapsed().as_millis() as u64,
                tokens_out,
                chosen_device,
                error: None,
            },
        );
        return;
    }

    // Streaming path: read SSE chunks until [DONE] / EOF.
    let mut stream = resp.bytes_stream();
    let mut ttft: Option<u64> = None;
    let mut tokens: u32 = 0;
    let mut first_saw_data = false;
    let mut buf = String::new();
    let mut errored: Option<String> = None;

    while let Some(next) = stream.next().await {
        match next {
            Ok(chunk) => {
                if !first_saw_data {
                    first_saw_data = true;
                    ttft = Some(started.elapsed().as_millis() as u64);
                }
                buf.push_str(&String::from_utf8_lossy(&chunk));
                while let Some(idx) = buf.find("\n\n") {
                    let block = buf[..idx].to_string();
                    buf = buf[idx + 2..].to_string();
                    for line in block.lines() {
                        if let Some(data) = line.strip_prefix("data: ") {
                            if data.trim() == "[DONE]" {
                                break;
                            }
                            if let Ok(v) = serde_json::from_str::<serde_json::Value>(data) {
                                if v.get("error").is_some() {
                                    errored = Some(data.to_string());
                                } else if v.pointer("/choices/0/delta/content").and_then(|x| x.as_str()).is_some() {
                                    tokens += 1;
                                }
                            }
                        }
                    }
                }
            }
            Err(e) => {
                errored = Some(format!("stream err: {}", e));
                break;
            }
        }
    }

    let status = if errored.is_some() { "stream_error" } else { "ok" };
    record_and_stat(
        writer,
        stats,
        RequestRecord {
            ts_unix_ms: now_ms(),
            run_id: run_id.to_string(),
            model: mix.model.clone(),
            prompt_tokens,
            max_tokens: mix.max_tokens,
            streaming: true,
            status: status.into(),
            http_status,
            ttft_ms: ttft,
            total_ms: started.elapsed().as_millis() as u64,
            tokens_out: Some(tokens),
            chosen_device,
            error: errored,
        },
    );
}

fn record_and_stat(
    writer: &Arc<RecordWriter>,
    stats: &Arc<parking_lot::Mutex<Stats>>,
    rec: RequestRecord,
) {
    if let Err(e) = writer.write(&rec) {
        warn!("record write: {}", e);
    }
    let mut s = stats.lock();
    s.total += 1;
    match rec.status.as_str() {
        "ok" => s.ok += 1,
        _ => s.errors += 1,
    }
    if let Some(tt) = rec.ttft_ms {
        s.ttft_samples.push(tt);
    }
    s.total_latency_ms.push(rec.total_ms);
}

fn build_messages(mix: &RequestMix, prompt_tokens: u32) -> serde_json::Value {
    // Heuristic: ~4 chars per token. Fill with lorem-ipsum so the backend has
    // real work to do.
    let approx_chars = (prompt_tokens as usize).saturating_mul(4);
    let filler = "Describe the following research log in detail. ".repeat((approx_chars / 48) + 1);
    let user = &filler[..filler.len().min(approx_chars.max(32))];

    if let Some(sys) = &mix.system_prompt {
        json!([
            {"role": "system", "content": sys},
            {"role": "user", "content": user},
        ])
    } else {
        json!([{ "role": "user", "content": user }])
    }
}

fn sample_normal_u32<R: Rng>(rng: &mut R, mean: u32, stddev: u32) -> u32 {
    if stddev == 0 {
        return mean;
    }
    let normal = Normal::new(mean as f64, stddev as f64).unwrap();
    let v = normal.sample(rng);
    v.max(1.0).round() as u32
}

fn try_count_tokens(text: &str) -> Option<u32> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    v.get("usage")?
        .get("completion_tokens")?
        .as_u64()
        .map(|x| x as u32)
}

#[derive(Debug, Default, Clone)]
pub struct Stats {
    pub total: u64,
    pub ok: u64,
    pub errors: u64,
    pub dropped: u64,
    pub ttft_samples: Vec<u64>,
    pub total_latency_ms: Vec<u64>,
}

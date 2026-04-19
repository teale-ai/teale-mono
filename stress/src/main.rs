//! teale-stress: load + fault-injection test runner for the gateway.
//!
//! Usage:
//!   teale-stress run --scenario scenarios/steady_state.toml --out runs/
//!   teale-stress analyze --run runs/20260418T120000
//!
//! Each `run` invocation produces a directory with:
//!   - records.jsonl     — per-request records
//!   - summary.json      — aggregate stats & pass/fail check
//!   - scenario.toml     — copy of input scenario

use std::path::PathBuf;
use std::sync::Arc;

use clap::{Parser, Subcommand};
use hdrhistogram::Histogram;
use tracing::info;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};
use uuid::Uuid;

mod faults;
mod loadgen;
mod record;
mod scenario;

use crate::loadgen::Stats;
use crate::record::RecordWriter;
use crate::scenario::Scenario;

#[derive(Parser)]
#[command(name = "teale-stress", about = "Stress test the teale gateway + fleet")]
struct Args {
    #[command(subcommand)]
    cmd: Command,
}

#[derive(Subcommand)]
enum Command {
    Run {
        #[arg(short, long)]
        scenario: String,
        #[arg(short, long, default_value = "runs")]
        out: PathBuf,
    },
    Analyze {
        #[arg(short, long)]
        run: PathBuf,
    },
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(fmt::layer().with_target(false))
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    let args = Args::parse();
    match args.cmd {
        Command::Run { scenario, out } => run(&scenario, &out).await,
        Command::Analyze { run } => analyze(&run),
    }
}

async fn run(scenario_path: &str, out_dir: &PathBuf) -> anyhow::Result<()> {
    let scn = Scenario::load(scenario_path)?;
    let run_id = format!("{}_{}", scn.name, Uuid::new_v4().simple());
    let run_dir = out_dir.join(&run_id);
    std::fs::create_dir_all(&run_dir)?;

    // Copy scenario for reproducibility.
    std::fs::copy(scenario_path, run_dir.join("scenario.toml"))?;

    let writer = Arc::new(RecordWriter::new(
        &run_dir.join("records.jsonl"),
        run_id.clone(),
    )?);

    // Schedule faults concurrently.
    if !scn.faults.is_empty() {
        faults::run_schedule(scn.faults.clone()).await;
    }

    info!(run_id, "starting run");
    let stats = loadgen::run(scn.clone(), writer.clone()).await?;
    writer.flush()?;

    let summary = summarize(&stats, &scn);
    std::fs::write(
        run_dir.join("summary.json"),
        serde_json::to_string_pretty(&summary)?,
    )?;

    println!("\nRun complete: {}", run_dir.display());
    println!("{}", serde_json::to_string_pretty(&summary)?);
    Ok(())
}

fn summarize(stats: &Stats, scn: &Scenario) -> serde_json::Value {
    let mut ttft = Histogram::<u64>::new_with_bounds(1, 600_000, 3).unwrap();
    for &v in &stats.ttft_samples {
        ttft.record(v).ok();
    }
    let mut lat = Histogram::<u64>::new_with_bounds(1, 600_000, 3).unwrap();
    for &v in &stats.total_latency_ms {
        lat.record(v).ok();
    }

    let success_rate = if stats.total > 0 {
        stats.ok as f64 / stats.total as f64
    } else {
        0.0
    };

    let pass_steady =
        success_rate >= 0.995 && ttft.value_at_quantile(0.95) <= 5_000 && stats.dropped == 0;

    serde_json::json!({
        "scenario": scn.name,
        "duration_seconds": scn.duration_seconds,
        "rps_target": scn.rps,
        "total_requests": stats.total,
        "ok": stats.ok,
        "errors": stats.errors,
        "dropped": stats.dropped,
        "success_rate": success_rate,
        "ttft_ms": {
            "p50": ttft.value_at_quantile(0.50),
            "p95": ttft.value_at_quantile(0.95),
            "p99": ttft.value_at_quantile(0.99),
            "max": ttft.max(),
        },
        "total_latency_ms": {
            "p50": lat.value_at_quantile(0.50),
            "p95": lat.value_at_quantile(0.95),
            "p99": lat.value_at_quantile(0.99),
            "max": lat.max(),
        },
        "pass_steady_state": pass_steady,
    })
}

fn analyze(run_dir: &PathBuf) -> anyhow::Result<()> {
    let summary_path = run_dir.join("summary.json");
    let summary = std::fs::read_to_string(&summary_path)?;
    println!("{}", summary);
    Ok(())
}

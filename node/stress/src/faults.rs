//! Fault injection — talks to nodes via SSH (or to a local proxy for
//! in-stream corruption). Requires passwordless SSH configured to the
//! target hosts.

use std::time::Duration;

use tokio::process::Command;
use tracing::{info, warn};

use crate::scenario::{FaultKind, FaultSchedule};

/// Schedule all faults to fire at their configured times.
pub async fn run_schedule(schedule: Vec<FaultSchedule>) {
    for f in schedule {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(f.at_seconds)).await;
            if let Err(e) = apply(&f).await {
                warn!(fault=?f.kind, "fault apply failed: {}", e);
            }
        });
    }
}

async fn apply(f: &FaultSchedule) -> anyhow::Result<()> {
    let target = f.target.as_deref().unwrap_or("localhost");
    info!(kind=?f.kind, target, "applying fault");
    match f.kind {
        FaultKind::KillBackend => ssh(target, "pkill -TERM -x llama-server || pkill -TERM -x mnn_llm || true").await,
        FaultKind::KillNode => ssh(target, "pkill -TERM -x teale-node || true").await,
        FaultKind::BlockWs => {
            // Outbound TCP to :443 blocked for duration. macOS/pfctl vs Linux/iptables.
            let pf = format!(
                "sudo pfctl -a teale-stress -f - <<'EOF'\nblock out proto tcp from any to any port 443\nEOF\nsudo pfctl -e || true"
            );
            ssh(target, &pf).await?;
            tokio::time::sleep(Duration::from_secs(f.duration_seconds)).await;
            ssh(target, "sudo pfctl -a teale-stress -F rules || true").await?;
            Ok(())
        }
        FaultKind::PauseHeartbeat => {
            // Send SIGSTOP to pause, SIGCONT to resume.
            ssh(target, "pkill -STOP -x teale-node || true").await?;
            tokio::time::sleep(Duration::from_secs(f.duration_seconds)).await;
            ssh(target, "pkill -CONT -x teale-node || true").await?;
            Ok(())
        }
        FaultKind::MalformedChunk => {
            // Requires the fault-injection proxy in front of llama-server;
            // see stress/README.md. Placeholder just logs.
            warn!("malformed_chunk fault requires proxy — not implemented in this build");
            Ok(())
        }
    }
}

async fn ssh(target: &str, cmd: &str) -> anyhow::Result<()> {
    if target == "localhost" || target.is_empty() {
        let output = Command::new("sh").arg("-c").arg(cmd).output().await?;
        log_status(&output);
        return Ok(());
    }
    let output = Command::new("ssh")
        .arg("-o")
        .arg("StrictHostKeyChecking=no")
        .arg("-o")
        .arg("ConnectTimeout=5")
        .arg(target)
        .arg(cmd)
        .output()
        .await?;
    log_status(&output);
    Ok(())
}

fn log_status(output: &std::process::Output) {
    if !output.status.success() {
        warn!(
            stdout = %String::from_utf8_lossy(&output.stdout),
            stderr = %String::from_utf8_lossy(&output.stderr),
            "ssh exit: {}",
            output.status
        );
    }
}

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
        FaultKind::KillBackend => {
            ssh(
                target,
                "pkill -TERM -x llama-server || pkill -TERM -x mnn_llm || true",
            )
            .await
        }
        // SIGKILL: simulates a crash (no graceful shutdown path runs).
        FaultKind::KillNode => ssh(target, "pkill -KILL -x teale-node || true").await,
        FaultKind::BlockWs => {
            // Outbound TCP to :443 blocked for duration: pfctl on macOS,
            // iptables on Linux. Failures are logged (no `|| true`).
            ssh(target, BLOCK_WS_CMD).await?;
            tokio::time::sleep(Duration::from_secs(f.duration_seconds)).await;
            ssh(target, UNBLOCK_WS_CMD).await?;
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

/// Block outbound TCP :443 (macOS pf anchor / Linux iptables rule tagged
/// `teale-stress` so the unblock removes only what we added).
const BLOCK_WS_CMD: &str = "if [ \"$(uname)\" = Darwin ]; then \
    printf 'block out proto tcp from any to any port 443\\n' | sudo pfctl -a teale-stress -f - \
    && { sudo pfctl -e 2>/dev/null || true; }; \
    else sudo iptables -I OUTPUT -p tcp --dport 443 \
    -m comment --comment teale-stress -j REJECT; fi";

const UNBLOCK_WS_CMD: &str = "if [ \"$(uname)\" = Darwin ]; then \
    sudo pfctl -a teale-stress -F rules; \
    else while sudo iptables -D OUTPUT -p tcp --dport 443 \
    -m comment --comment teale-stress -j REJECT 2>/dev/null; do :; done; fi";

async fn ssh(target: &str, cmd: &str) -> anyhow::Result<()> {
    if target == "localhost" || target.is_empty() {
        let output = Command::new("sh").arg("-c").arg(cmd).output().await?;
        log_status(&output);
        return Ok(());
    }
    // Host keys are verified against known_hosts (no StrictHostKeyChecking=no);
    // BatchMode makes an unknown/changed host fail instead of prompting.
    let output = Command::new("ssh")
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("ConnectTimeout=5")
        .arg(target)
        .arg(cmd)
        .output()
        .await?;
    log_status(&output);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_ws_covers_macos_and_linux() {
        assert!(BLOCK_WS_CMD.contains("pfctl -a teale-stress -f -"));
        assert!(BLOCK_WS_CMD.contains("iptables -I OUTPUT"));
        assert!(UNBLOCK_WS_CMD.contains("pfctl -a teale-stress -F rules"));
        assert!(UNBLOCK_WS_CMD.contains("iptables -D OUTPUT"));
        // The unblock must delete exactly the rule the block inserted.
        let rule = "-p tcp --dport 443 -m comment --comment teale-stress -j REJECT";
        assert!(BLOCK_WS_CMD.contains(rule));
        assert!(UNBLOCK_WS_CMD.contains(rule));
    }
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

//! Offline dataset integrity and held-out gates, not benchmark execution/authentication.
use anyhow::{bail, Context, Result};
use clap::Args;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Args)]
pub struct CalibrationArgs {
    /// Local manifest; raw run files must be regular nonsymlink files alongside it.
    #[arg(long)]
    manifest: PathBuf,
    /// Maximum raw-run age in seconds, supplied explicitly. No freshness default.
    #[arg(long)]
    max_age_seconds: u64,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    version: u32,
    /// Locks cost model identity used by predictions before held-out collection.
    predictor_sha256: String,
    training_run_ids: Vec<String>,
    held_out: Vec<Entry>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    file: String,
    sha256: String,
    prediction: Prediction,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Identity {
    device_id: String,
    backend_binary_sha256: String,
    artifact_sha256: String,
    backend_revision: String,
    configuration_sha256: String,
    context_tokens: u64,
    concurrency: u64,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Prediction {
    run_id: String,
    identity: Identity,
    predicted_at_unix: u64,
    predictor_sha256: String,
    modeled_fit: bool,
    predicted_decode_tps: Option<f64>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawRun {
    version: u32,
    run_id: String,
    identity: Identity,
    collected_at_unix: u64,
    /// Collector claims only: this file's digest does not authenticate its author.
    fit_outcome: FitOutcome,
    observed_peak_bytes: Option<u64>,
    capacity_bytes: u64,
    /// Plain decode only, excludes prefill; successful tokens across declared workload.
    decode_tokens: Option<u64>,
    decode_seconds: Option<f64>,
    cancelled: bool,
    tool_eval_passed: bool,
}
#[derive(Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum FitOutcome {
    Loaded,
    Oom,
    AllocationFailed,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    run_id: String,
    device_id: String,
    false_fit: bool,
    predicted_fit: bool,
    observed_fit: bool,
    decode_relative_error: Option<f64>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Report {
    verdict: &'static str,
    held_out_cases: usize,
    devices: usize,
    false_fit_cases: usize,
    decode_cases: usize,
    median_decode_relative_error: Option<f64>,
    min_held_out_cases: usize,
    min_decode_cases: usize,
    min_devices: usize,
    rows: Vec<Row>,
    failures: Vec<String>,
    caveats: Vec<&'static str>,
}
fn sha(value: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        bail!("expected lowercase SHA-256 digest");
    }
    Ok(())
}
fn validate_identity(i: &Identity) -> Result<()> {
    for d in [
        &i.artifact_sha256,
        &i.backend_binary_sha256,
        &i.configuration_sha256,
    ] {
        sha(d)?;
    }
    if i.device_id.trim().is_empty()
        || i.backend_revision.trim().is_empty()
        || i.context_tokens == 0
        || i.concurrency == 0
    {
        bail!("complete artifact/backend/device/workload identity required");
    }
    Ok(())
}
fn same_identity(a: &Identity, b: &Identity) -> bool {
    a.device_id == b.device_id
        && a.backend_binary_sha256 == b.backend_binary_sha256
        && a.artifact_sha256 == b.artifact_sha256
        && a.backend_revision == b.backend_revision
        && a.configuration_sha256 == b.configuration_sha256
        && a.context_tokens == b.context_tokens
        && a.concurrency == b.concurrency
}
fn age(timestamp: u64, now: u64, max: u64) -> Result<()> {
    let age = now
        .checked_sub(timestamp)
        .context("future-dated evidence rejected")?;
    if timestamp == 0 || age > max {
        bail!("stale or undated evidence");
    }
    Ok(())
}
fn regular(path: &Path) -> Result<()> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_file() || m.file_type().is_symlink() {
        bail!("evidence must be a regular nonsymlink file");
    }
    if m.len() > 8 * 1024 * 1024 {
        bail!("evidence file exceeds 8 MiB");
    }
    Ok(())
}
fn read_run(root: &Path, e: &Entry) -> Result<RawRun> {
    let p = Path::new(&e.file);
    // One filename, no nested symlink components or absolute/path traversal escapes.
    if p.components().count() != 1 || !matches!(p.components().next(), Some(Component::Normal(_))) {
        bail!("raw run file must be one relative filename");
    }
    sha(&e.sha256)?;
    let p = root.join(p);
    regular(&p)?;
    let bytes = fs::read(&p)?;
    if format!("{:x}", Sha256::digest(&bytes)) != e.sha256 {
        bail!("raw evidence digest mismatch");
    }
    Ok(serde_json::from_slice(&bytes)?)
}
fn median(mut values: Vec<f64>) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let n = values.len();
    Some(if n % 2 == 1 {
        values[n / 2]
    } else {
        (values[n / 2 - 1] + values[n / 2]) / 2.0
    })
}
fn evaluate(manifest: Manifest, root: &Path, now: u64, max_age: u64) -> Result<Report> {
    if manifest.version != 1 || max_age == 0 || manifest.held_out.len() > 10_000 {
        bail!("version 1, positive max age and <=10000 cases required");
    }
    sha(&manifest.predictor_sha256)?;
    let mut seen = BTreeSet::new();
    for id in &manifest.training_run_ids {
        if id.trim().is_empty() || !seen.insert(id.clone()) {
            bail!("training IDs must be unique/nonempty");
        }
    }
    if seen.is_empty() {
        bail!("training run identifiers required for held-out separation");
    }
    let mut rows = Vec::new();
    let mut errors = Vec::new();
    let mut devices = BTreeSet::new();
    let mut failures = Vec::new();
    let mut configs = BTreeSet::new();
    for e in manifest.held_out {
        let p = e.prediction;
        validate_identity(&p.identity)?;
        sha(&p.predictor_sha256)?;
        if p.predictor_sha256 != manifest.predictor_sha256
            || p.run_id.trim().is_empty()
            || !seen.insert(p.run_id.clone())
        {
            bail!("prediction identity mismatch, duplicate case or training leakage");
        }
        let e = Entry { prediction: p, ..e };
        let r = read_run(root, &e)?;
        let p = e.prediction;
        validate_identity(&r.identity)?;
        if r.version != 1 || r.run_id != p.run_id || !same_identity(&r.identity, &p.identity) {
            bail!("raw run identity/workload differs from prediction");
        }
        age(r.collected_at_unix, now, max_age)?;
        age(p.predicted_at_unix, now, max_age)?;
        if p.predicted_at_unix >= r.collected_at_unix {
            bail!("prediction must precede held-out collection");
        }
        if r.capacity_bytes == 0 {
            bail!("raw capacity must be positive");
        }
        let loaded = r.fit_outcome == FitOutcome::Loaded;
        if loaded && r.observed_peak_bytes.is_none() {
            bail!("successful load needs observed peak bytes");
        }
        if loaded
            && r.observed_peak_bytes
                .is_some_and(|peak| peak > r.capacity_bytes)
        {
            bail!("loaded peak contradicts reported capacity");
        }
        if r.cancelled || !r.tool_eval_passed {
            failures.push(format!("{}: cancelled or tool/eval failed", r.run_id));
        }
        let error = match (p.predicted_decode_tps, r.decode_tokens, r.decode_seconds) {
            (Some(predicted), Some(tokens), Some(seconds)) => {
                if !loaded
                    || r.cancelled
                    || !r.tool_eval_passed
                    || !predicted.is_finite()
                    || predicted <= 0.0
                    || tokens == 0
                    || !seconds.is_finite()
                    || seconds <= 0.0
                {
                    bail!("decode evidence must be successful, finite and positive");
                }
                let observed = tokens as f64 / seconds;
                let relative = (predicted - observed).abs() / observed;
                if !observed.is_finite() || !relative.is_finite() {
                    bail!("nonfinite decode rate/error");
                }
                errors.push(relative);
                Some(relative)
            }
            (None, None, None) => None,
            _ => bail!("prediction and raw decode tokens/seconds must be present together"),
        };
        devices.insert(r.identity.device_id.clone());
        configs.insert((r.identity.context_tokens, r.identity.concurrency));
        rows.push(Row {
            run_id: r.run_id,
            device_id: r.identity.device_id,
            false_fit: p.modeled_fit && !loaded,
            predicted_fit: p.modeled_fit,
            observed_fit: loaded,
            decode_relative_error: error,
        });
    }
    let false_fit = rows.iter().filter(|r| r.false_fit).count();
    let mid = median(errors.clone());
    // Explicit initial proof rubric, not statistical universality or runtime admission.
    if rows.len() < 20 {
        failures.push("need >=20 held-out fit cases".into());
    }
    if rows
        .iter()
        .filter(|r| r.predicted_fit && r.observed_fit)
        .count()
        < 20
    {
        failures.push(
            "need >=20 predicted-fit successful load cases (no vacuous all-reject pass)".into(),
        );
    }
    if devices.len() < 2 {
        failures.push("need >=2 device identities".into());
    }
    if errors.len() < 20 {
        failures.push("need >=20 successful held-out decode cases".into());
    }
    if configs
        .iter()
        .map(|(ctx, _)| ctx)
        .collect::<BTreeSet<_>>()
        .len()
        < 2
        || configs
            .iter()
            .map(|(_, c)| c)
            .collect::<BTreeSet<_>>()
            .len()
            < 2
    {
        failures.push("need >=2 contexts and >=2 concurrency settings".into());
    }
    if false_fit > 0 {
        failures.push(format!(
            "{false_fit} false-fit/OOM/allocation-failure cases"
        ));
    }
    if mid.is_none_or(|v| v > 0.20) {
        failures.push("median held-out relative decode error exceeds 20% or is absent".into());
    }
    Ok(Report{verdict:if failures.is_empty(){"supplied_dataset_pass"}else{"supplied_dataset_fails_or_incomplete"},held_out_cases:rows.len(),devices:devices.len(),false_fit_cases:false_fit,decode_cases:errors.len(),median_decode_relative_error:mid,min_held_out_cases:20,min_decode_cases:20,min_devices:2,rows,failures,caveats:vec![
        "Raw file digests, schema, identity, age and split checks validate supplied dataset consistency, not author authenticity or truthful measurement.",
        "Prediction timestamps and training IDs are supplied claims. Use a trusted immutable collector and pre-registration outside this command.",
        "Observed peak/capacity must share the limiting physical domain; other domains remain the collector's responsibility.",
        "Passing this finite dataset does not prove zero false-fit universally or authorize automatic selection/routing.",
        "No benchmark, model load, backend execution, network request, spend or configuration change occurred."]})
}
pub fn run(args: CalibrationArgs) -> Result<()> {
    regular(&args.manifest)?;
    let manifest: Manifest = serde_json::from_slice(&fs::read(&args.manifest)?)?;
    let root = args.manifest.parent().unwrap_or_else(|| Path::new("."));
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let report = evaluate(manifest, root, now, args.max_age_seconds)?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn raw(id: &str) -> serde_json::Value {
        serde_json::json!({"version":1,"runId":id,"identity":{"deviceId":"lab-a","backendBinarySha256":"a".repeat(64),"artifactSha256":"b".repeat(64),"backendRevision":"pinned","configurationSha256":"c".repeat(64),"contextTokens":4096,"concurrency":1},"collectedAtUnix":1000,"fitOutcome":"loaded","observedPeakBytes":80,"capacityBytes":100,"decodeTokens":100,"decodeSeconds":2.0,"cancelled":false,"toolEvalPassed":true})
    }
    fn manifest(root: &Path, rows: Vec<serde_json::Value>) -> Manifest {
        let entries:Vec<_>=rows.iter().enumerate().map(|(n,r)| {
            let file=format!("run-{n}.json");let bytes=serde_json::to_vec(r).unwrap();fs::write(root.join(&file),&bytes).unwrap();
            let loaded=r["fitOutcome"]=="loaded";
            serde_json::json!({"file":file,"sha256":format!("{:x}",Sha256::digest(&bytes)),"prediction":{"runId":r["runId"],"identity":r["identity"],"predictedAtUnix":900,"predictorSha256":"d".repeat(64),"modeledFit":loaded,"predictedDecodeTps":if loaded {Some(50.0)} else {None}}})
        }).collect();
        serde_json::from_value(serde_json::json!({"version":1,"predictorSha256":"d".repeat(64),"trainingRunIds":["train-1"],"heldOut":entries})).unwrap()
    }
    #[test]
    fn incomplete_dataset_never_passes() {
        let root = tempfile::tempdir().unwrap();
        let m = manifest(root.path(), vec![raw("test")]);
        let r = evaluate(m, root.path(), 1100, 1000).unwrap();
        assert_eq!(r.verdict, "supplied_dataset_fails_or_incomplete");
        assert_eq!(r.false_fit_cases, 0);
        assert_eq!(r.median_decode_relative_error, Some(0.0));
    }
    #[test]
    fn stale_future_posthoc_and_training_leakage_rejected() {
        let root = tempfile::tempdir().unwrap();
        assert!(evaluate(
            manifest(root.path(), vec![raw("test")]),
            root.path(),
            1100,
            99
        )
        .is_err());
        assert!(evaluate(
            manifest(root.path(), vec![raw("test")]),
            root.path(),
            999,
            1000
        )
        .is_err());
        let mut m = manifest(root.path(), vec![raw("test")]);
        m.held_out[0].prediction.predicted_at_unix = 1000;
        assert!(evaluate(m, root.path(), 1100, 1000).is_err());
        assert!(evaluate(
            manifest(root.path(), vec![raw("train-1")]),
            root.path(),
            1100,
            1000
        )
        .is_err());
    }
    #[test]
    fn raw_digest_path_traversal_identity_and_duplicate_rejected() {
        let root = tempfile::tempdir().unwrap();
        let mut m = manifest(root.path(), vec![raw("test")]);
        m.held_out[0].sha256 = "e".repeat(64);
        assert!(evaluate(m, root.path(), 1100, 1000).is_err());
        let mut m = manifest(root.path(), vec![raw("test")]);
        m.held_out[0].file = "../run-0.json".into();
        assert!(evaluate(m, root.path(), 1100, 1000).is_err());
        let mut m = manifest(root.path(), vec![raw("test")]);
        m.held_out[0].prediction.identity.concurrency = 2;
        assert!(evaluate(m, root.path(), 1100, 1000).is_err());
        assert!(evaluate(
            manifest(root.path(), vec![raw("test"), raw("test")]),
            root.path(),
            1100,
            1000
        )
        .is_err());
    }
    #[test]
    fn oom_false_fit_reported_without_decode() {
        let root = tempfile::tempdir().unwrap();
        let mut r = raw("oom");
        r["fitOutcome"] = "oom".into();
        r["observedPeakBytes"] = serde_json::Value::Null;
        r["decodeTokens"] = serde_json::Value::Null;
        r["decodeSeconds"] = serde_json::Value::Null;
        let mut m = manifest(root.path(), vec![r]);
        m.held_out[0].prediction.modeled_fit = true;
        let r = evaluate(m, root.path(), 1100, 1000).unwrap();
        assert_eq!(r.false_fit_cases, 1);
        assert_ne!(r.verdict, "supplied_dataset_pass");
    }
    #[test]
    fn finite_dataset_pass_and_error_gate() {
        let root = tempfile::tempdir().unwrap();
        let mut raws = Vec::new();
        for n in 0..22 {
            let mut r = raw(&format!("held-{n}"));
            r["identity"]["deviceId"] = if n % 2 == 0 { "lab-a" } else { "lab-b" }.into();
            r["identity"]["contextTokens"] = if n % 2 == 0 { 4096 } else { 32768 }.into();
            r["identity"]["concurrency"] = if n % 2 == 0 { 1 } else { 2 }.into();
            if n >= 20 {
                r["fitOutcome"] = "allocation_failed".into();
                r["observedPeakBytes"] = serde_json::Value::Null;
                r["decodeTokens"] = serde_json::Value::Null;
                r["decodeSeconds"] = serde_json::Value::Null;
            }
            raws.push(r);
        }
        let r = evaluate(manifest(root.path(), raws.clone()), root.path(), 1100, 1000).unwrap();
        assert_eq!(r.verdict, "supplied_dataset_pass");
        let mut m = manifest(root.path(), raws);
        for e in &mut m.held_out[..20] {
            e.prediction.predicted_decode_tps = Some(61.0);
        }
        assert_eq!(
            evaluate(m, root.path(), 1100, 1000).unwrap().verdict,
            "supplied_dataset_fails_or_incomplete"
        );
    }
    #[test]
    fn invalid_peak_decode_and_symlink_rejected() {
        let root = tempfile::tempdir().unwrap();
        let mut r = raw("test");
        r["observedPeakBytes"] = 101.into();
        assert!(evaluate(manifest(root.path(), vec![r]), root.path(), 1100, 1000).is_err());
        let mut r = raw("test");
        r["decodeSeconds"] = 0.into();
        assert!(evaluate(manifest(root.path(), vec![r]), root.path(), 1100, 1000).is_err());
        #[cfg(unix)]
        {
            let m = manifest(root.path(), vec![raw("test")]);
            fs::rename(
                root.path().join("run-0.json"),
                root.path().join("original.json"),
            )
            .unwrap();
            std::os::unix::fs::symlink("original.json", root.path().join("run-0.json")).unwrap();
            assert!(evaluate(m, root.path(), 1100, 1000).is_err());
        }
    }
    #[test]
    fn median_is_relative_error_not_biased_signed_error() {
        assert_eq!(median(vec![0.1, 0.3]), Some(0.2));
        assert_eq!(median(vec![0.4, 0.1, 0.2]), Some(0.2));
        assert_eq!(median(vec![]), None);
    }
}

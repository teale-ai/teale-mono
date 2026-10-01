//! Local source-snapshot consistency/age audit. Never claims live authenticity.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path};
use std::time::{SystemTime, UNIX_EPOCH};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Registry {
    version: u32,
    sources: Vec<Source>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    source: String,
    as_of: String,
    basis: String,
    checked_at_unix: u64,
    snapshot_file: String,
    snapshot_sha256: String,
    benchmark_id: Option<String>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Audit {
    status: &'static str,
    evidence_entries: usize,
    unique_snapshots: usize,
    max_age_seconds: u64,
    unverified_assumed_or_modeled_entries: usize,
    caveats: Vec<&'static str>,
}
fn read_bounded(path: &Path) -> Result<Vec<u8>> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_file() || m.file_type().is_symlink() || m.len() > 8 * 1024 * 1024 {
        bail!("source registry/snapshot must be a regular nonsymlink file <=8 MiB");
    }
    let bytes = fs::read(path)?;
    if bytes.len() > 8 * 1024 * 1024 {
        bail!("source grew past limit");
    }
    Ok(bytes)
}
fn collect<'a>(value: &'a Value, entries: &mut Vec<&'a Value>) {
    match value {
        Value::Object(o) => {
            for (key, v) in o {
                if key == "evidence" {
                    entries.push(v);
                } else {
                    collect(v, entries);
                }
            }
        }
        Value::Array(a) => {
            for v in a {
                collect(v, entries);
            }
        }
        _ => {}
    }
}
fn audit(registry: Registry, root: &Path, max: u64, now: u64, plan: &Value) -> Result<Audit> {
    if registry.version != 1 || max == 0 || registry.sources.len() > 10_000 {
        bail!("registry version 1, positive max age, <=10000 sources required");
    }
    let mut sources = BTreeMap::new();
    for s in registry.sources {
        if !matches!(s.basis.as_str(), "published" | "reported" | "measured")
            || s.source.trim().is_empty()
            || s.as_of.trim().is_empty()
        {
            bail!("registry needs published/reported/measured basis, exact source and asOf");
        }
        let age = now
            .checked_sub(s.checked_at_unix)
            .context("future source check timestamp")?;
        if s.checked_at_unix == 0 || age > max {
            bail!("stale or undated source check");
        }
        let p = Path::new(&s.snapshot_file);
        if p.components().count() != 1
            || !matches!(p.components().next(), Some(Component::Normal(_)))
        {
            bail!("snapshot must be one relative filename");
        }
        if s.snapshot_sha256.len() != 64
            || !s
                .snapshot_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            bail!("invalid snapshot SHA-256");
        }
        let bytes = read_bounded(&root.join(p))?;
        if format!("{:x}", Sha256::digest(&bytes)) != s.snapshot_sha256 {
            bail!("source snapshot digest mismatch");
        }
        if s.basis == "measured"
            && s.benchmark_id
                .as_deref()
                .is_none_or(|id| id.trim().is_empty())
        {
            bail!("measured snapshot needs benchmarkId");
        }
        let key = (s.source.clone(), s.as_of.clone(), s.basis.clone());
        if sources.insert(key, s).is_some() {
            bail!("duplicate source/version/basis registry entry");
        }
    }
    let mut entries = Vec::new();
    collect(plan, &mut entries);
    let mut used = BTreeSet::new();
    let mut unverified = 0;
    for e in &entries {
        let field = |key| {
            e.get(key)
                .and_then(Value::as_str)
                .context("malformed evidence object")
        };
        let basis = field("basis")?;
        if matches!(basis, "assumed" | "modeled") {
            unverified += 1;
            continue;
        }
        let key = (
            field("source")?.to_owned(),
            field("asOf")?.to_owned(),
            basis.to_owned(),
        );
        let s = sources
            .get(&key)
            .context("evidence lacks matching source/version/basis snapshot")?;
        if basis == "measured"
            && e.get("benchmarkId").and_then(Value::as_str) != s.benchmark_id.as_deref()
        {
            bail!("benchmark identifier differs from source snapshot");
        }
        used.insert(s.snapshot_file.clone());
    }
    Ok(Audit{status:"local_snapshot_consistency_checked",evidence_entries:entries.len(),unique_snapshots:used.len(),max_age_seconds:max,unverified_assumed_or_modeled_entries:unverified,caveats:vec![
        "Digest verifies supplied snapshot bytes; source ownership, content truth and its relationship to numeric charges are not authenticated.",
        "checkedAtUnix is a supplied assertion; a fresh timestamp cannot prove the live source is unchanged or still current.",
        "asOf matches exactly but is not interpreted as a publication/revision date. Assumed/modeled evidence is not verified.",
        "Measured snapshot digest/benchmarkId is not raw run validation; use validate-evidence separately.",
        "No external fetch, benchmark, model load or routing change occurred. This audit does not promote modeled fit to a measured guarantee."]})
}
pub fn check(path: &Path, max: u64, plan: &Value) -> Result<Audit> {
    let registry = serde_json::from_slice(&read_bounded(path)?)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    audit(
        registry,
        path.parent().unwrap_or_else(|| Path::new(".")),
        max,
        now,
        plan,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    fn setup(root: &Path) -> (Registry, Value) {
        fs::write(root.join("source.txt"), b"synthetic source").unwrap();
        let s = Source {
            source: "synthetic://hardware".into(),
            as_of: "v1".into(),
            basis: "reported".into(),
            checked_at_unix: 1000,
            snapshot_file: "source.txt".into(),
            snapshot_sha256: format!("{:x}", Sha256::digest(b"synthetic source")),
            benchmark_id: None,
        };
        let p = serde_json::json!({"domains":[{"capacity":{"value":100,"evidence":{"basis":"reported","source":"synthetic://hardware","asOf":"v1"}},"reserve":{"value":10,"evidence":{"basis":"assumed","source":"test","asOf":"v1"}}}]});
        (
            Registry {
                version: 1,
                sources: vec![s],
            },
            p,
        )
    }
    #[test]
    fn local_snapshot_only_preserves_unverified_count() {
        let root = tempfile::tempdir().unwrap();
        let (r, p) = setup(root.path());
        let a = audit(r, root.path(), 200, 1100, &p).unwrap();
        assert_eq!(a.status, "local_snapshot_consistency_checked");
        assert_eq!(a.evidence_entries, 2);
        assert_eq!(a.unique_snapshots, 1);
        assert_eq!(a.unverified_assumed_or_modeled_entries, 1);
    }
    #[test]
    fn stale_future_missing_and_wrong_version_rejected() {
        let root = tempfile::tempdir().unwrap();
        let (r, p) = setup(root.path());
        assert!(audit(r, root.path(), 99, 1100, &p).is_err());
        let (r, p) = setup(root.path());
        assert!(audit(r, root.path(), 200, 999, &p).is_err());
        let (r, mut p) = setup(root.path());
        p["domains"][0]["capacity"]["evidence"]["asOf"] = "v2".into();
        assert!(audit(r, root.path(), 200, 1100, &p).is_err());
        let (_, p) = setup(root.path());
        assert!(audit(
            Registry {
                version: 1,
                sources: vec![]
            },
            root.path(),
            200,
            1100,
            &p
        )
        .is_err());
    }
    #[test]
    fn digest_path_duplicate_and_benchmark_mismatch_rejected() {
        let root = tempfile::tempdir().unwrap();
        let (mut r, p) = setup(root.path());
        r.sources[0].snapshot_sha256 = "0".repeat(64);
        assert!(audit(r, root.path(), 200, 1100, &p).is_err());
        let (mut r, p) = setup(root.path());
        r.sources[0].snapshot_file = "../source.txt".into();
        assert!(audit(r, root.path(), 200, 1100, &p).is_err());
        let (mut r, mut p) = setup(root.path());
        r.sources[0].basis = "measured".into();
        r.sources[0].benchmark_id = Some("run1".into());
        p["domains"][0]["capacity"]["evidence"]["basis"] = "measured".into();
        p["domains"][0]["capacity"]["evidence"]["benchmarkId"] = "run2".into();
        assert!(audit(r, root.path(), 200, 1100, &p).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn snapshot_symlink_rejected() {
        let root = tempfile::tempdir().unwrap();
        let (r, p) = setup(root.path());
        fs::rename(
            root.path().join("source.txt"),
            root.path().join("original.txt"),
        )
        .unwrap();
        std::os::unix::fs::symlink("original.txt", root.path().join("source.txt")).unwrap();
        assert!(audit(r, root.path(), 200, 1100, &p).is_err());
    }
}

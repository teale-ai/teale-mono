//! Read-only load-plan assessment. Does not select/load a model or change routing.
//! Every byte term carries provenance; predictions never become measured facts.
use anyhow::{bail, Context, Result};
use clap::Args;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::PathBuf;

#[derive(Args)]
pub struct AssessmentArgs {
    /// JSON load plan with per-domain charges and evidence (see docs/model-fit-assessment.md).
    #[arg(long)]
    plan: PathBuf,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Basis {
    Reported,
    Published,
    Assumed,
    Modeled,
    Measured,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Evidence {
    basis: Basis,
    source: String,
    /// ISO timestamp or dated source version; persisted as provided, not a freshness claim.
    as_of: String,
    /// Required for measured evidence; must identify retrievable raw run evidence.
    #[serde(default)]
    benchmark_id: Option<String>,
}
impl Evidence {
    fn validate(&self) -> Result<()> {
        if self.source.trim().is_empty() || self.as_of.trim().is_empty() {
            bail!("evidence needs source and asOf");
        }
        if self.basis == Basis::Measured
            && self
                .benchmark_id
                .as_deref()
                .is_none_or(|id| id.trim().is_empty())
        {
            bail!("measured evidence needs benchmarkId");
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Bytes {
    value: u64,
    evidence: Evidence,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Plan {
    version: u32,
    device_id: String,
    backend: String,
    backend_revision: String,
    model_id: String,
    artifact_id: String,
    context_tokens: u64,
    concurrency: u64,
    domains: Vec<Domain>,
    /// Optional plain-decode cost model. No speculative speed multiplier is invented.
    #[serde(default)]
    decode: Option<Decode>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Domain {
    id: String,
    capacity: Bytes,
    reserve: Bytes,
    /// Already allocated bytes outside this load plan, including other resident models.
    occupied: Bytes,
    weights: Bytes,
    /// Whole configured context, per request. Derived from the exact backend codec/layout.
    kv_per_request: Bytes,
    /// Peak shared scratch for the declared batch/concurrency, not per request.
    scratch_peak: Bytes,
    /// Complete draft weights/state/scratch peak for the declared method; explicit zero for none.
    draft_peak: Bytes,
    overhead: Bytes,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Number {
    value: f64,
    evidence: Evidence,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Decode {
    bandwidth_bytes_per_second: Number,
    weight_efficiency: Number,
    history_efficiency: Number,
    streamed_weight_bytes: Bytes,
    history_bytes: Bytes,
    launch_count: u64,
    launch_seconds: Number,
    step_seconds: Number,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DomainResult {
    id: String,
    capacity: Bytes,
    required_bytes: u64,
    remaining_bytes: i128,
    fits: bool,
    terms: Vec<Charge>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Charge {
    name: &'static str,
    bytes: u64,
    evidence: Evidence,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Estimate {
    kind: &'static str,
    tokens_per_second: f64,
    seconds_per_token: f64,
    evidence: Vec<Evidence>,
    caveat: &'static str,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Assessment {
    version: u32,
    device_id: String,
    backend: String,
    backend_revision: String,
    model_id: String,
    artifact_id: String,
    context_tokens: u64,
    concurrency: u64,
    verdict: &'static str,
    limiting_domain: String,
    domains: Vec<DomainResult>,
    decode: Option<Estimate>,
    caveats: Vec<&'static str>,
}
fn evaluate(plan: Plan) -> Result<Assessment> {
    if plan.version != 1
        || plan.domains.is_empty()
        || plan.context_tokens == 0
        || plan.concurrency == 0
    {
        bail!("version 1, nonempty domains, positive context/concurrency required");
    }
    for id in [
        &plan.device_id,
        &plan.backend,
        &plan.backend_revision,
        &plan.model_id,
        &plan.artifact_id,
    ] {
        if id.trim().is_empty() {
            bail!("device/backend/revision/model/artifact identity required");
        }
    }
    let mut ids = BTreeSet::new();
    let mut results = Vec::new();
    for domain in plan.domains {
        if domain.id.trim().is_empty() || !ids.insert(domain.id.clone()) {
            bail!("domain IDs must be nonempty and unique");
        }
        if domain.capacity.value == 0 {
            bail!("domain capacity must be positive");
        }
        let kv = domain
            .kv_per_request
            .value
            .checked_mul(plan.concurrency)
            .context("KV byte overflow")?;
        let components = [
            ("reserve", domain.reserve.value, &domain.reserve),
            ("occupied", domain.occupied.value, &domain.occupied),
            ("weights", domain.weights.value, &domain.weights),
            ("kv_all_requests", kv, &domain.kv_per_request),
            (
                "scratch_peak",
                domain.scratch_peak.value,
                &domain.scratch_peak,
            ),
            ("draft_peak", domain.draft_peak.value, &domain.draft_peak),
            ("overhead", domain.overhead.value, &domain.overhead),
        ];
        domain.capacity.evidence.validate()?;
        let mut required = 0u64;
        let mut terms = Vec::new();
        for (name, bytes, input) in components {
            input.evidence.validate()?;
            required = required
                .checked_add(bytes)
                .context("domain byte overflow")?;
            terms.push(Charge {
                name,
                bytes,
                evidence: input.evidence.clone(),
            });
        }
        let remaining = i128::from(domain.capacity.value) - i128::from(required);
        results.push(DomainResult {
            id: domain.id,
            capacity: domain.capacity,
            required_bytes: required,
            remaining_bytes: remaining,
            fits: remaining >= 0,
            terms,
        });
    }
    let limiting = results
        .iter()
        .min_by_key(|d| d.remaining_bytes)
        .unwrap()
        .id
        .clone();
    let fits = results.iter().all(|d| d.fits);
    let decode = plan.decode.map(estimate).transpose()?;
    Ok(Assessment{version:1,device_id:plan.device_id,backend:plan.backend,backend_revision:plan.backend_revision,
        model_id:plan.model_id,artifact_id:plan.artifact_id,context_tokens:plan.context_tokens,concurrency:plan.concurrency,
        verdict:if fits {"modeled_fit"} else {"modeled_does_not_fit"},limiting_domain:limiting,domains:results,decode,
        caveats:vec!["Load-plan inputs are supplied evidence, not independently verified or freshness-checked.",
        "A modeled fit is not an allocation guarantee, measured safe load, or routing recommendation.",
        "Charges must include all shards, aliases charged once per physical domain, backend KV layout and peak scratch/draft at this workload.",
        "Decode estimate is plain single-request decode at the declared context, not TTFT, task time, speculative speed, or earnings.",
        "No model load, download, benchmark, API call, wallet action or configuration change occurred."]})
}
fn estimate(input: Decode) -> Result<Estimate> {
    let numbers = [
        &input.bandwidth_bytes_per_second,
        &input.weight_efficiency,
        &input.history_efficiency,
        &input.launch_seconds,
        &input.step_seconds,
    ];
    for n in numbers {
        n.evidence.validate()?;
        if !n.value.is_finite() || n.value < 0.0 {
            bail!("decode cost must be finite and nonnegative");
        }
    }
    let bw = input.bandwidth_bytes_per_second.value;
    let we = input.weight_efficiency.value;
    let he = input.history_efficiency.value;
    if bw <= 0.0 || !(0.0 < we && we <= 1.0 && 0.0 < he && he <= 1.0) {
        bail!("positive bandwidth and efficiencies in (0,1] required");
    }
    input.streamed_weight_bytes.evidence.validate()?;
    input.history_bytes.evidence.validate()?;
    let seconds = input.step_seconds.value
        + input.launch_seconds.value * input.launch_count as f64
        + input.streamed_weight_bytes.value as f64 / (bw * we)
        + input.history_bytes.value as f64 / (bw * he);
    let tps = 1.0 / seconds;
    if !seconds.is_finite() || seconds <= 0.0 || !tps.is_finite() {
        bail!("decode estimate must be finite and positive");
    }
    let mut evidence = numbers
        .iter()
        .map(|n| n.evidence.clone())
        .collect::<Vec<_>>();
    evidence.push(input.streamed_weight_bytes.evidence);
    evidence.push(input.history_bytes.evidence);
    Ok(Estimate{kind:"analytical_plain_decode",tokens_per_second:tps,seconds_per_token:seconds,evidence,
        caveat:"Prediction from supplied costs. Do not relabel measured even when individual inputs were measured."})
}
pub fn run(args: AssessmentArgs) -> Result<()> {
    let plan: Plan = serde_json::from_slice(&std::fs::read(args.plan)?)
        .context("invalid assessment load plan")?;
    let assessed = evaluate(plan)?;
    println!("{}", serde_json::to_string_pretty(&assessed)?);
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn bytes(value: u64) -> Bytes {
        Bytes {
            value,
            evidence: Evidence {
                basis: Basis::Assumed,
                source: "fixture".into(),
                as_of: "2026-10-01".into(),
                benchmark_id: None,
            },
        }
    }
    fn plan() -> Plan {
        Plan {
            version: 1,
            device_id: "lab".into(),
            backend: "llama".into(),
            backend_revision: "pinned".into(),
            model_id: "test".into(),
            artifact_id: "artifact-digest".into(),
            context_tokens: 4096,
            concurrency: 2,
            domains: vec![Domain {
                id: "unified".into(),
                capacity: bytes(100),
                reserve: bytes(10),
                occupied: bytes(10),
                weights: bytes(40),
                kv_per_request: bytes(10),
                scratch_peak: bytes(5),
                draft_peak: bytes(0),
                overhead: bytes(5),
            }],
            decode: None,
        }
    }
    #[test]
    fn charges_kv_per_request_only_and_preserves_basis() {
        let a = evaluate(plan()).unwrap();
        assert_eq!(a.verdict, "modeled_fit");
        assert_eq!(a.domains[0].required_bytes, 90);
        assert_eq!(a.domains[0].remaining_bytes, 10);
        assert_eq!(a.domains[0].terms[3].bytes, 20);
        assert_eq!(a.domains[0].terms[3].evidence.basis, Basis::Assumed);
    }
    #[test]
    fn capacity_cliff_and_limiting_domain() {
        let mut p = plan();
        p.domains[0].capacity.value = 89;
        let a = evaluate(p).unwrap();
        assert_eq!(a.verdict, "modeled_does_not_fit");
        assert_eq!(a.domains[0].remaining_bytes, -1);
    }
    #[test]
    fn equality_is_modeled_fit_not_measured() {
        let mut p = plan();
        p.domains[0].capacity.value = 90;
        assert_eq!(evaluate(p).unwrap().verdict, "modeled_fit");
    }
    #[test]
    fn overflow_missing_evidence_and_fake_measurement_rejected() {
        let mut p = plan();
        p.concurrency = u64::MAX;
        assert!(evaluate(p).is_err());
        let mut p = plan();
        p.domains[0].weights.evidence.source.clear();
        assert!(evaluate(p).is_err());
        let mut p = plan();
        p.domains[0].capacity.evidence.basis = Basis::Measured;
        assert!(evaluate(p).is_err());
    }
    #[test]
    fn duplicate_domains_rejected() {
        let mut p = plan();
        let mut second = plan().domains.remove(0);
        second.id = "unified".into();
        p.domains.push(second);
        assert!(evaluate(p).is_err());
    }
    #[test]
    fn independent_domain_deficit_cannot_hide_in_total_capacity() {
        let mut p = plan();
        let mut second = plan().domains.remove(0);
        second.id = "vram".into();
        second.capacity.value = 50;
        p.domains[0].capacity.value = 1000;
        p.domains.push(second);
        let a = evaluate(p).unwrap();
        assert_eq!(a.verdict, "modeled_does_not_fit");
        assert_eq!(a.limiting_domain, "vram");
    }
    #[test]
    fn plain_decode_prediction_never_becomes_measured() {
        let number = |value| Number {
            value,
            evidence: bytes(0).evidence,
        };
        let i = Decode {
            bandwidth_bytes_per_second: number(100.0),
            weight_efficiency: number(1.0),
            history_efficiency: number(1.0),
            streamed_weight_bytes: bytes(10),
            history_bytes: bytes(10),
            launch_count: 2,
            launch_seconds: number(0.1),
            step_seconds: number(0.1),
        };
        let a = estimate(i).unwrap();
        assert!((a.tokens_per_second - 2.0).abs() < 1e-10);
        assert_eq!(a.kind, "analytical_plain_decode");
    }
}

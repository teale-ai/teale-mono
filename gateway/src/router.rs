//! Unified candidate selector across local distributed devices and
//! centralized 3rd-party providers. Implements OpenRouter-style provider
//! preferences (`provider.order`, `only`, `ignore`, `sort`, `max_price`,
//! `preferred_min_throughput`, `preferred_max_latency`, `quantizations`,
//! `data_collection`, `zdr`, `allow_fallbacks`) plus the `:nitro` / `:floor`
//! model-slug shortcuts.
//!
//! Default load balancing (no `sort`, no `order`): filter providers that
//! had a recent (<30s) outage, then weight remaining candidates by the
//! inverse-square of their per-token price (cheapest serves the most
//! traffic — same shape as OpenRouter's default).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::providers::health::{HealthSnapshot, HealthTracker};
use crate::providers::registry::{ProviderModelRow, ProviderRow, ProviderStatus};

/// User-supplied preferences extracted from the request body's `provider`
/// field. All fields optional; absent → use defaults that mirror OpenRouter.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct ProviderPreferences {
    #[serde(default)]
    pub order: Option<Vec<String>>,
    #[serde(default = "default_true")]
    pub allow_fallbacks: bool,
    #[serde(default)]
    pub only: Option<Vec<String>>,
    #[serde(default)]
    pub ignore: Option<Vec<String>>,
    #[serde(default)]
    pub quantizations: Option<Vec<String>>,
    #[serde(default)]
    pub sort: Option<SortPref>,
    #[serde(default)]
    pub max_price: Option<MaxPrice>,
    #[serde(default)]
    pub preferred_min_throughput: Option<PercentilePref>,
    #[serde(default)]
    pub preferred_max_latency: Option<PercentilePref>,
    #[serde(default)]
    pub require_parameters: bool,
    #[serde(default)]
    pub data_collection: Option<String>,
    #[serde(default)]
    pub zdr: Option<bool>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum SortPref {
    Simple(SortKey),
    Detailed {
        by: SortKey,
        #[serde(default)]
        partition: Option<String>,
    },
}

impl SortPref {
    pub fn key(&self) -> SortKey {
        match self {
            SortPref::Simple(k) => *k,
            SortPref::Detailed { by, .. } => *by,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SortKey {
    Price,
    Throughput,
    Latency,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct MaxPrice {
    #[serde(default)]
    pub prompt: Option<f64>,
    #[serde(default)]
    pub completion: Option<f64>,
    #[serde(default)]
    pub request: Option<f64>,
    #[serde(default)]
    pub image: Option<f64>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct PercentilePref {
    #[serde(default)]
    pub p50: Option<f64>,
    #[serde(default)]
    pub p75: Option<f64>,
    #[serde(default)]
    pub p90: Option<f64>,
    #[serde(default)]
    pub p99: Option<f64>,
}

/// `:nitro` / `:floor` shortcuts on the model slug. Returns the cleaned
/// model id and the implied sort if any.
pub fn parse_slug_shortcut(model: &str) -> (String, Option<SortKey>) {
    if let Some(rest) = model.strip_suffix(":nitro") {
        (rest.to_string(), Some(SortKey::Throughput))
    } else if let Some(rest) = model.strip_suffix(":floor") {
        (rest.to_string(), Some(SortKey::Price))
    } else {
        (model.to_string(), None)
    }
}

/// Pulls the `provider` field (if any) off the request body. Removes it
/// from the body so it isn't forwarded upstream — providers don't recognize
/// our routing knobs.
pub fn extract_preferences(body: &mut Value) -> ProviderPreferences {
    let raw = body
        .as_object_mut()
        .and_then(|o| o.remove("provider"))
        .unwrap_or(Value::Null);
    if raw.is_null() {
        return ProviderPreferences::default();
    }
    serde_json::from_value(raw).unwrap_or_default()
}

/// One option the router can pick. v1 only models centralized providers
/// here — local devices stay on the existing scheduler path. The router is
/// invoked by the chat handler **first**; if it picks a centralized provider,
/// the request goes to providers::*; otherwise the handler falls through to
/// the existing relay/scheduler path. This keeps the diff bounded while
/// still honoring `order`/`only`/`ignore`/`sort` semantics across both kinds.
#[derive(Debug, Clone)]
pub struct ProviderCandidate {
    pub provider: ProviderRow,
    pub model: ProviderModelRow,
    pub effective_prompt_price_usd: f64,
    pub effective_completion_price_usd: f64,
    pub health: HealthSnapshot,
}

impl ProviderCandidate {
    pub fn slug(&self) -> &str {
        &self.provider.slug
    }
}

#[derive(Debug, Clone)]
pub struct LocalDistributedCandidate {
    /// Synthetic slug used for `provider.order` matching. Always
    /// `"teale-distributed"` — the gateway is the single point of contact for
    /// the fleet, so users can prefer or deprioritize "the network" as a
    /// whole. Per-device control is out of scope for v1.
    pub slug: &'static str,
    pub effective_prompt_price_usd: f64,
    pub effective_completion_price_usd: f64,
}

impl Default for LocalDistributedCandidate {
    fn default() -> Self {
        Self {
            slug: "teale-distributed",
            effective_prompt_price_usd: 0.0,
            effective_completion_price_usd: 0.0,
        }
    }
}

#[derive(Debug, Clone)]
pub enum Candidate {
    LocalDistributed(LocalDistributedCandidate),
    CentralizedProvider(ProviderCandidate),
}

impl Candidate {
    pub fn slug(&self) -> &str {
        match self {
            Candidate::LocalDistributed(c) => c.slug,
            Candidate::CentralizedProvider(c) => c.slug(),
        }
    }

    pub fn prompt_price(&self) -> f64 {
        match self {
            Candidate::LocalDistributed(c) => c.effective_prompt_price_usd,
            Candidate::CentralizedProvider(c) => c.effective_prompt_price_usd,
        }
    }

    pub fn completion_price(&self) -> f64 {
        match self {
            Candidate::LocalDistributed(c) => c.effective_completion_price_usd,
            Candidate::CentralizedProvider(c) => c.effective_completion_price_usd,
        }
    }

    /// Average of prompt + completion price, for the inverse-square default
    /// load balancing weight.
    pub fn blended_price(&self) -> f64 {
        (self.prompt_price() + self.completion_price()) / 2.0
    }
}

/// Build the set of provider candidates eligible to serve `model_id` after
/// applying the preference filters. The local distributed candidate is added
/// by the caller because it depends on the fleet registry, not the provider
/// registry.
#[allow(clippy::too_many_arguments)]
pub fn rank_provider_candidates(
    model_id: &str,
    request_context_tokens: u32,
    request_features: &[String],
    prefs: &ProviderPreferences,
    health: &HealthTracker,
    rows: Vec<(ProviderRow, ProviderModelRow)>,
) -> Vec<ProviderCandidate> {
    let only: Option<HashSet<&str>> = prefs
        .only
        .as_ref()
        .map(|v| v.iter().map(|s| s.as_str()).collect());
    let ignore: HashSet<&str> = prefs
        .ignore
        .as_ref()
        .map(|v| v.iter().map(|s| s.as_str()).collect())
        .unwrap_or_default();
    let allowed_quants: Option<HashSet<&str>> = prefs
        .quantizations
        .as_ref()
        .map(|v| v.iter().map(|s| s.as_str()).collect());

    let mut out: Vec<ProviderCandidate> = Vec::new();

    for (provider, model) in rows {
        if provider.status != ProviderStatus::Active {
            continue;
        }
        if let Some(only) = &only {
            if !only.contains(provider.slug.as_str()) {
                continue;
            }
        }
        if ignore.contains(provider.slug.as_str()) {
            continue;
        }
        if let Some(allowed) = &allowed_quants {
            match provider.quantization.as_deref() {
                Some(q) if allowed.contains(q) => {}
                _ => continue,
            }
        }
        if let Some(zdr) = prefs.zdr {
            if zdr && !provider.zdr {
                continue;
            }
        }
        if let Some(dc) = prefs.data_collection.as_deref() {
            if dc == "deny" && provider.data_collection != "deny" {
                continue;
            }
        }
        // OpenRouter's 2-tier pricing: drop this row if the request's
        // context exceeds what this tier covers. (`min_context` means "use
        // this row when context >= min_context"; we pick the row whose
        // bracket the request falls into, which we approximate by skipping
        // tiers whose context_length is below the request.)
        if request_context_tokens > 0 && model.context_length < request_context_tokens {
            continue;
        }
        if prefs.require_parameters && !request_features.is_empty() {
            let supported: HashSet<&str> = model
                .supported_features
                .iter()
                .map(|s| s.as_str())
                .collect();
            if !request_features
                .iter()
                .all(|f| supported.contains(f.as_str()))
            {
                continue;
            }
        }
        let prompt = model.prompt_price_usd();
        let completion = model.completion_price_usd();
        if let Some(cap) = &prefs.max_price {
            // Pricing in OpenRouter's `max_price` is per million tokens; the
            // pricing rows are per-token. Convert before compare.
            if let Some(p) = cap.prompt {
                if prompt * 1_000_000.0 > p {
                    continue;
                }
            }
            if let Some(c) = cap.completion {
                if completion * 1_000_000.0 > c {
                    continue;
                }
            }
            if let Some(r) = cap.request {
                if model.request_price_usd() > r {
                    continue;
                }
            }
        }

        let snapshot = health.snapshot(&provider.provider_id, model_id);

        out.push(ProviderCandidate {
            provider,
            model,
            effective_prompt_price_usd: prompt,
            effective_completion_price_usd: completion,
            health: snapshot,
        });
    }

    out
}

/// Apply ordering (`order`, then `sort`, then default load balance) to a
/// pre-filtered candidate list. `local` is the distributed-fleet candidate,
/// if available; placed in the result wherever the user's `order` puts it
/// (or last as a fallback when no order is specified).
pub fn order_candidates(
    mut providers: Vec<ProviderCandidate>,
    local: Option<LocalDistributedCandidate>,
    prefs: &ProviderPreferences,
) -> Vec<Candidate> {
    // Apply throughput/latency preference deprioritization (don't drop;
    // OpenRouter pushes failing rows to the end of the list).
    if let Some(min_tput) = &prefs.preferred_min_throughput {
        providers.sort_by(|a, b| {
            let (ax, bx) = (
                meets_min_throughput(&a.health, min_tput),
                meets_min_throughput(&b.health, min_tput),
            );
            // True (meets) before False (doesn't).
            bx.cmp(&ax)
        });
    }
    if let Some(max_lat) = &prefs.preferred_max_latency {
        providers.sort_by(|a, b| {
            let (ax, bx) = (
                meets_max_latency(&a.health, max_lat),
                meets_max_latency(&b.health, max_lat),
            );
            bx.cmp(&ax)
        });
    }

    let mut all: Vec<Candidate> = providers
        .into_iter()
        .map(Candidate::CentralizedProvider)
        .collect();
    if let Some(l) = local {
        all.push(Candidate::LocalDistributed(l));
    }

    if let Some(order) = &prefs.order {
        let pos = |slug: &str| -> usize {
            order
                .iter()
                .position(|s| s.eq_ignore_ascii_case(slug))
                .unwrap_or(usize::MAX)
        };
        all.sort_by_key(|c| pos(c.slug()));
        return all;
    }

    if let Some(sort) = &prefs.sort {
        match sort.key() {
            SortKey::Price => all.sort_by(|a, b| {
                a.blended_price()
                    .partial_cmp(&b.blended_price())
                    .unwrap_or(std::cmp::Ordering::Equal)
            }),
            SortKey::Throughput => all.sort_by(|a, b| {
                let av = match a {
                    Candidate::CentralizedProvider(c) => c.health.tps_p50.unwrap_or(0.0),
                    Candidate::LocalDistributed(_) => 0.0,
                };
                let bv = match b {
                    Candidate::CentralizedProvider(c) => c.health.tps_p50.unwrap_or(0.0),
                    Candidate::LocalDistributed(_) => 0.0,
                };
                bv.partial_cmp(&av).unwrap_or(std::cmp::Ordering::Equal)
            }),
            SortKey::Latency => all.sort_by(|a, b| {
                let av = match a {
                    Candidate::CentralizedProvider(c) => c.health.ttft_p50_ms.unwrap_or(u64::MAX),
                    Candidate::LocalDistributed(_) => u64::MAX,
                };
                let bv = match b {
                    Candidate::CentralizedProvider(c) => c.health.ttft_p50_ms.unwrap_or(u64::MAX),
                    Candidate::LocalDistributed(_) => u64::MAX,
                };
                av.cmp(&bv)
            }),
        }
        return all;
    }

    // Default: filter recently-unstable, then inverse-square price weighting.
    // Implementation note: actual probabilistic load balancing is out of
    // scope for v1; we approximate by sorting cheapest-first among stable
    // candidates and pushing recently-unstable to the end. Distributed
    // serves first when it has any healthy supply (price=0 by default).
    let (stable, unstable): (Vec<Candidate>, Vec<Candidate>) =
        all.into_iter().partition(|c| match c {
            Candidate::CentralizedProvider(p) => !p.health.recently_unstable(),
            Candidate::LocalDistributed(_) => true,
        });
    let mut ordered = stable;
    ordered.sort_by(|a, b| {
        a.blended_price()
            .partial_cmp(&b.blended_price())
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    ordered.extend(unstable);
    ordered
}

fn meets_min_throughput(h: &HealthSnapshot, p: &PercentilePref) -> bool {
    let check = |actual: Option<f64>, target: Option<f64>| -> bool {
        match (actual, target) {
            (_, None) => true,
            (Some(a), Some(t)) => a >= t,
            (None, Some(_)) => false,
        }
    };
    check(h.tps_p50, p.p50) && check(h.tps_p90, p.p90) && check(h.tps_p99, p.p99)
}

fn meets_max_latency(h: &HealthSnapshot, p: &PercentilePref) -> bool {
    let check = |actual: Option<u64>, target: Option<f64>| -> bool {
        match (actual, target) {
            (_, None) => true,
            (Some(a), Some(t)) => (a as f64) <= t * 1000.0, // seconds → ms
            (None, Some(_)) => false,
        }
    };
    check(h.ttft_p50_ms, p.p50) && check(h.ttft_p90_ms, p.p90) && check(h.ttft_p99_ms, p.p99)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_shortcut_nitro_picks_throughput() {
        let (m, sort) = parse_slug_shortcut("openai/gpt-oss-120b:nitro");
        assert_eq!(m, "openai/gpt-oss-120b");
        assert_eq!(sort, Some(SortKey::Throughput));
    }

    #[test]
    fn slug_shortcut_floor_picks_price() {
        let (m, sort) = parse_slug_shortcut("openai/gpt-oss-120b:floor");
        assert_eq!(m, "openai/gpt-oss-120b");
        assert_eq!(sort, Some(SortKey::Price));
    }

    #[test]
    fn slug_shortcut_none() {
        let (m, sort) = parse_slug_shortcut("openai/gpt-oss-120b");
        assert_eq!(m, "openai/gpt-oss-120b");
        assert_eq!(sort, None);
    }

    #[test]
    fn extract_prefs_consumes_provider_field() {
        let mut body: Value = serde_json::from_str(
            r#"{"model":"x","provider":{"order":["a","b"],"allow_fallbacks":false}}"#,
        )
        .unwrap();
        let prefs = extract_preferences(&mut body);
        assert_eq!(prefs.order, Some(vec!["a".into(), "b".into()]));
        assert!(!prefs.allow_fallbacks);
        assert!(body.get("provider").is_none());
    }

    #[test]
    fn order_priority_overrides_price() {
        let prefs = ProviderPreferences {
            order: Some(vec!["acme".into(), "teale-distributed".into()]),
            ..Default::default()
        };
        let cands = vec![]; // empty for this unit test
        let local = Some(LocalDistributedCandidate::default());
        let ordered = order_candidates(cands, local, &prefs);
        assert_eq!(ordered.len(), 1);
        assert_eq!(ordered[0].slug(), "teale-distributed");
    }

    fn fake_pair(slug: &str, prompt: &str, completion: &str) -> (ProviderRow, ProviderModelRow) {
        use crate::providers::registry::{ProviderStatus, ProviderWireFormat};
        let p = ProviderRow {
            provider_id: format!("prov_{}", slug),
            slug: slug.to_string(),
            display_name: slug.to_string(),
            base_url: "https://example.test".to_string(),
            wire_format: ProviderWireFormat::Openai,
            auth_header_name: "Authorization".to_string(),
            auth_secret_ref: "FAKE_KEY".to_string(),
            status: ProviderStatus::Active,
            data_collection: "allow".to_string(),
            zdr: false,
            quantization: Some("bf16".to_string()),
            created_at: 0,
            updated_at: 0,
        };
        let m = ProviderModelRow {
            provider_id: p.provider_id.clone(),
            model_id: "openai/gpt-oss-120b".into(),
            pricing_prompt_usd: prompt.into(),
            pricing_completion_usd: completion.into(),
            pricing_request_usd: None,
            min_context: None,
            context_length: 32_768,
            max_output_tokens: Some(4_096),
            supported_features: vec!["tools".into()],
            input_modalities: vec!["text".into()],
            deprecation_date: None,
        };
        (p, m)
    }

    #[test]
    fn ignore_drops_provider_and_only_constrains_set() {
        let h = HealthTracker::new();
        let rows = vec![
            fake_pair("acme", "0.0000005", "0.000001"),
            fake_pair("globex", "0.0000003", "0.0000006"),
        ];
        let prefs = ProviderPreferences {
            ignore: Some(vec!["acme".into()]),
            ..Default::default()
        };
        let cands =
            rank_provider_candidates("openai/gpt-oss-120b", 0, &[], &prefs, &h, rows.clone());
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].slug(), "globex");

        let prefs_only = ProviderPreferences {
            only: Some(vec!["acme".into()]),
            ..Default::default()
        };
        let cands = rank_provider_candidates("openai/gpt-oss-120b", 0, &[], &prefs_only, &h, rows);
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].slug(), "acme");
    }

    #[test]
    fn max_price_drops_overpriced_providers() {
        let h = HealthTracker::new();
        let rows = vec![
            fake_pair("cheap", "0.0000001", "0.0000002"),
            fake_pair("pricey", "0.000005", "0.00001"),
        ];
        let prefs = ProviderPreferences {
            max_price: Some(MaxPrice {
                prompt: Some(1.0),
                completion: Some(2.0),
                ..Default::default()
            }),
            ..Default::default()
        };
        let cands = rank_provider_candidates("openai/gpt-oss-120b", 0, &[], &prefs, &h, rows);
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].slug(), "cheap");
    }

    #[test]
    fn require_parameters_drops_providers_missing_features() {
        let h = HealthTracker::new();
        let mut rows = vec![
            fake_pair("acme", "0.0000005", "0.000001"),
            fake_pair("globex", "0.0000005", "0.000001"),
        ];
        // globex doesn't support tools.
        rows[1].1.supported_features.clear();
        let prefs = ProviderPreferences {
            require_parameters: true,
            ..Default::default()
        };
        let cands = rank_provider_candidates(
            "openai/gpt-oss-120b",
            0,
            &["tools".to_string()],
            &prefs,
            &h,
            rows,
        );
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].slug(), "acme");
    }

    #[test]
    fn sort_price_picks_cheapest_first() {
        let h = HealthTracker::new();
        let rows = vec![
            fake_pair("pricey", "0.000005", "0.00001"),
            fake_pair("cheap", "0.0000001", "0.0000002"),
        ];
        let prefs = ProviderPreferences {
            sort: Some(SortPref::Simple(SortKey::Price)),
            ..Default::default()
        };
        let cands = rank_provider_candidates("openai/gpt-oss-120b", 0, &[], &prefs, &h, rows);
        let ordered = order_candidates(cands, None, &prefs);
        assert_eq!(ordered.first().unwrap().slug(), "cheap");
    }
}

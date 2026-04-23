use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct WindowsCatalogModel {
    pub id: &'static str,
    pub display_name: &'static str,
    pub download_urls: &'static [&'static str],
    pub file_name: &'static str,
    pub size_gb: f64,
    pub required_ram_gb: f64,
    pub default_context: u32,
    pub max_context: u32,
    pub demand_rank: u32,
    pub pricing_prompt_usd: f64,
    pub pricing_completion_usd: f64,
}

pub const AVAILABILITY_TICK_SECONDS: u64 = 1;
pub const HERMES_REFERENCE_PROMPT_PRICE_USD: f64 = 0.00000010;
pub const HERMES_REFERENCE_COMPLETION_PRICE_USD: f64 = 0.00000020;

pub const WINDOWS_MODEL_CATALOG: &[WindowsCatalogModel] = &[
    WindowsCatalogModel {
        id: "nousresearch/hermes-3-llama-3.1-8b",
        display_name: "Hermes 3 (Llama 3.1 8B) Q5_K_M",
        download_urls: &[
            "https://huggingface.co/NousResearch/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B.Q5_K_M.gguf",
        ],
        file_name: "hermes-3-llama-3.1-8b-Q5_K_M.gguf",
        size_gb: 5.7,
        required_ram_gb: 16.0,
        default_context: 8192,
        max_context: 32768,
        demand_rank: 1,
        pricing_prompt_usd: 0.00000010,
        pricing_completion_usd: 0.00000020,
    },
    WindowsCatalogModel {
        id: "meta-llama/llama-3.1-8b-instruct",
        display_name: "Llama 3.1 8B Instruct Q4_K_M",
        download_urls: &[
            "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
        ],
        file_name: "llama-3.1-8b-instruct-Q4_K_M.gguf",
        size_gb: 4.9,
        required_ram_gb: 16.0,
        default_context: 8192,
        max_context: 16384,
        demand_rank: 2,
        pricing_prompt_usd: 0.00000010,
        pricing_completion_usd: 0.00000020,
    },
    WindowsCatalogModel {
        id: "qwen/qwen3-8b",
        display_name: "Qwen 3 8B Q4_K_M",
        download_urls: &[
            "https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf",
        ],
        file_name: "qwen3-8b-Q4_K_M.gguf",
        size_gb: 5.1,
        required_ram_gb: 24.0,
        default_context: 16384,
        max_context: 40960,
        demand_rank: 3,
        pricing_prompt_usd: 0.00000010,
        pricing_completion_usd: 0.00000020,
    },
    WindowsCatalogModel {
        id: "mistralai/mistral-small-3.2-24b-instruct",
        display_name: "Mistral Small 3.2 24B Instruct Q4_K_M",
        download_urls: &[
            "https://huggingface.co/bartowski/Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf",
        ],
        file_name: "mistral-small-3.2-24b-instruct-Q4_K_M.gguf",
        size_gb: 15.2,
        required_ram_gb: 32.0,
        default_context: 16384,
        max_context: 131072,
        demand_rank: 4,
        pricing_prompt_usd: 0.00000040,
        pricing_completion_usd: 0.00000080,
    },
    WindowsCatalogModel {
        id: "meta-llama/llama-3.3-70b-instruct",
        display_name: "Llama 3.3 70B Instruct Q4_K_M",
        download_urls: &[
            "https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf",
        ],
        file_name: "llama-3.3-70b-instruct-Q4_K_M.gguf",
        size_gb: 42.5,
        required_ram_gb: 64.0,
        default_context: 32768,
        max_context: 65536,
        demand_rank: 5,
        pricing_prompt_usd: 0.00000080,
        pricing_completion_usd: 0.00000160,
    },
];

impl WindowsCatalogModel {
    pub fn availability_credits_per_tick(&self) -> i64 {
        availability_credits_per_tick(self.pricing_prompt_usd, self.pricing_completion_usd)
    }

    pub fn availability_credits_per_minute(&self) -> i64 {
        self.availability_credits_per_tick() * (60 / AVAILABILITY_TICK_SECONDS) as i64
    }
}

pub fn availability_credits_per_tick(prompt_price_usd: f64, completion_price_usd: f64) -> i64 {
    let combined_price = prompt_price_usd.max(0.0) + completion_price_usd.max(0.0);
    let hermes_reference =
        HERMES_REFERENCE_PROMPT_PRICE_USD + HERMES_REFERENCE_COMPLETION_PRICE_USD;

    if combined_price <= 0.0 {
        return 1;
    }

    ((combined_price / hermes_reference).round() as i64).max(1)
}

pub fn compatible_models(total_ram_gb: f64) -> Vec<WindowsCatalogModel> {
    WINDOWS_MODEL_CATALOG
        .iter()
        .filter(|m| m.required_ram_gb <= total_ram_gb)
        .cloned()
        .collect()
}

pub fn recommended_model(total_ram_gb: f64) -> Option<WindowsCatalogModel> {
    let budget_gb = if total_ram_gb <= 16.0 {
        total_ram_gb
    } else {
        total_ram_gb * 0.75
    };
    WINDOWS_MODEL_CATALOG
        .iter()
        .find(|m| m.required_ram_gb <= budget_gb)
        .cloned()
}

pub fn model_by_id(model_id: &str) -> Option<WindowsCatalogModel> {
    WINDOWS_MODEL_CATALOG
        .iter()
        .find(|m| m.id == model_id)
        .cloned()
}

pub fn model_by_file_name(file_name: &str) -> Option<WindowsCatalogModel> {
    let lower = file_name.to_ascii_lowercase();
    WINDOWS_MODEL_CATALOG
        .iter()
        .find(|m| {
            m.file_name.eq_ignore_ascii_case(file_name)
                || lower.contains(
                    &m.file_name
                        .to_ascii_lowercase()
                        .trim_end_matches(".gguf")
                        .to_string(),
                )
        })
        .cloned()
}

pub fn context_for_model(
    model: &WindowsCatalogModel,
    total_ram_gb: f64,
    gpu_backend: Option<&str>,
) -> u32 {
    if matches!(gpu_backend, Some("cpu")) {
        return model.default_context;
    }

    let spare_ram_gb = (total_ram_gb - model.required_ram_gb).max(0.0);
    let mut context = model.default_context;

    if spare_ram_gb >= 4.0 {
        context = context.saturating_mul(2);
    }
    if spare_ram_gb >= 12.0 {
        context = context.saturating_mul(2);
    }
    if spare_ram_gb >= 24.0 {
        context = context.saturating_mul(2);
    }

    context.min(model.max_context)
}

#[cfg(test)]
mod tests {
    use super::{
        availability_credits_per_tick, context_for_model, recommended_model, WINDOWS_MODEL_CATALOG,
    };

    #[test]
    fn recommendation_prefers_first_that_fits_budget() {
        let hermes = recommended_model(16.0).expect("16 GB should fit Hermes");
        assert_eq!(hermes.id, WINDOWS_MODEL_CATALOG[0].id);

        let qwen = recommended_model(48.0).expect("48 GB should fit Qwen");
        assert_eq!(qwen.id, WINDOWS_MODEL_CATALOG[0].id);

        let big = recommended_model(96.0).expect("96 GB should fit at least one model");
        assert_eq!(big.id, WINDOWS_MODEL_CATALOG[0].id);
    }

    #[test]
    fn availability_rate_scales_from_hermes_pricing() {
        assert_eq!(availability_credits_per_tick(0.00000010, 0.00000020), 1);
        assert_eq!(availability_credits_per_tick(0.00000040, 0.00000080), 4);
        assert_eq!(availability_credits_per_tick(0.00000080, 0.00000160), 8);
    }

    #[test]
    fn larger_ram_devices_get_more_context_for_same_model() {
        let hermes = &WINDOWS_MODEL_CATALOG[0];
        assert_eq!(context_for_model(hermes, 16.0, Some("vulkan")), 8192);
        assert_eq!(context_for_model(hermes, 24.0, Some("vulkan")), 16384);
        assert_eq!(context_for_model(hermes, 32.0, Some("vulkan")), 32768);
    }

    #[test]
    fn cpu_backend_keeps_default_context() {
        let hermes = &WINDOWS_MODEL_CATALOG[0];
        assert_eq!(context_for_model(hermes, 32.0, Some("cpu")), 8192);
    }
}

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
    pub demand_rank: u32,
}

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
        demand_rank: 1,
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
        demand_rank: 2,
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
        demand_rank: 3,
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
        demand_rank: 4,
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
        demand_rank: 5,
    },
];

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

#[cfg(test)]
mod tests {
    use super::{recommended_model, WINDOWS_MODEL_CATALOG};

    #[test]
    fn recommendation_prefers_first_that_fits_budget() {
        let hermes = recommended_model(16.0).expect("16 GB should fit Hermes");
        assert_eq!(hermes.id, WINDOWS_MODEL_CATALOG[0].id);

        let qwen = recommended_model(48.0).expect("48 GB should fit Qwen");
        assert_eq!(qwen.id, WINDOWS_MODEL_CATALOG[0].id);

        let big = recommended_model(96.0).expect("96 GB should fit at least one model");
        assert_eq!(big.id, WINDOWS_MODEL_CATALOG[0].id);
    }
}

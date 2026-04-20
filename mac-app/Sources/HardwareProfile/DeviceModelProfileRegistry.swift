import Foundation
import SharedTypes

// MARK: - Device Model Profile Registry

/// Curated profiles mapping (device class, model) → optimal llama.cpp parameters.
/// Profiles are ordered by specificity: model-specific entries override device-class defaults.
public struct DeviceModelProfileRegistry: Sendable {

    // MARK: - Built-in Profiles

    public static let profiles: [DeviceModelProfile] = [

        // ════════════════════════════════════════════════════════════════════
        // Ultra Desktop (M*Ultra, 64-192+ GB) — maximize quality and throughput
        // ════════════════════════════════════════════════════════════════════

        // --- 256GB+ Ultra: flagship models with large context ---
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            minRAMGB: 256,
            params: InferenceProfile(
                contextSize: 65536,
                kvCacheType: "q8_0",
                batchSize: 4096,
                flashAttn: true,
                mmap: true,
                parallelSlots: 4,
                gpuLayers: 999
            ),
            notes: "Ultra 256GB+ — flagship models, full quality, high throughput"
        ),

        // MiniMax M2.7 on 256GB+ Ultra: ~243GB model, needs q4 KV for context headroom
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            modelFamily: "MiniMax",
            minRAMGB: 256,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q4_0",
                batchSize: 2048,
                flashAttn: true,
                mmap: true,
                parallelSlots: 2
            ),
            notes: "MiniMax M2.7 Q8 (~243GB) on 512GB Ultra — q4 KV to leave room for 32K context"
        ),

        // Qwen3-235B on 256GB+ Ultra: MoE, ~233GB weights, generous context
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            modelFamily: "Qwen",
            minRAMGB: 256,
            params: InferenceProfile(
                contextSize: 65536,
                kvCacheType: "q8_0",
                parallelSlots: 4,
                reasoningOff: true
            ),
            notes: "Qwen3-235B on 512GB Ultra — MoE is memory-efficient, full context"
        ),

        // GLM-5.1 UD-Q4_K_XL (~434GB) on 512GB Ultra — MLA keeps KV cache small,
        // push per-slot ctx to match the 128K catalog promise. 256K total pool
        // across 2 parallel slots → 128K per request. KV cache at q8_0 stays
        // under ~21 GB; leaves ~40 GB headroom on a 512 GB machine.
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            modelFamily: "GLM",
            minRAMGB: 256,
            params: InferenceProfile(
                contextSize: 262144,
                kvCacheType: "q8_0",
                batchSize: 4096,
                flashAttn: true,
                mmap: true,
                parallelSlots: 2,
                gpuLayers: 999,
                reasoningOff: true
            ),
            notes: "GLM-5.1 Q4 on 512GB Ultra — 128K per-slot context (catalog-promised), 2 concurrent slots"
        ),

        // --- 64-192GB Ultra: mid-tier, must budget carefully ---
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            maxRAMGB: 256,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q8_0",
                batchSize: 4096,
                flashAttn: true,
                mmap: true,
                parallelSlots: 2,
                gpuLayers: 999
            ),
            notes: "Ultra 64-192GB — good throughput, conservative context to leave KV headroom"
        ),

        // Llama 70B on 96GB Ultra: tested at 96K ctx (16GB KV), fits with ~6GB headroom
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            modelFamily: "Llama",
            minRAMGB: 80,
            maxRAMGB: 128,
            params: InferenceProfile(
                contextSize: 98304,
                kvCacheType: "q8_0",
                batchSize: 4096,
                flashAttn: true,
                mmap: true,
                parallelSlots: 1
            ),
            notes: "Llama-70B Q8 on 96GB Ultra — 96K context verified stable, single slot for headroom"
        ),

        // Llama 4 Scout 109B on Ultra: still memory-heavy, dial back context
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            modelID: "llama-4-scout-17b-16e-instruct-4bit",
            minRAMGB: 72,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q4_0",
                batchSize: 2048,
                parallelSlots: 2
            ),
            notes: "109B MoE needs memory headroom even on Ultra"
        ),

        // Qwen models on Ultra (64-192GB): disable reasoning, conservative context
        DeviceModelProfile(
            deviceClass: .ultraDesktop,
            modelFamily: "Qwen",
            maxRAMGB: 256,
            params: InferenceProfile(
                contextSize: 32768,
                reasoningOff: true
            ),
            notes: "Qwen on mid-tier Ultra — reasoning off, 32K context to conserve memory"
        ),

        // ════════════════════════════════════════════════════════════════════
        // Max Desktop (M*Max, 32-128 GB) — high-end, slightly constrained
        // Memory bandwidth: ~400 GB/s (M2 Max), ~600 GB/s (M3/M4 Max)
        // Rule of thumb: leave 20-25% RAM free for KV cache + system
        // ════════════════════════════════════════════════════════════════════

        DeviceModelProfile(
            deviceClass: .maxDesktop,
            minRAMGB: 48,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q8_0",
                batchSize: 2048,
                flashAttn: true,
                mmap: true,
                parallelSlots: 2,
                gpuLayers: 999
            ),
            notes: "Max desktop 48GB+ — full offload, good throughput"
        ),

        // Qwen3-32B Q8 (~34GB) on 64GB Max: sweet spot, room for 32K context
        DeviceModelProfile(
            deviceClass: .maxDesktop,
            modelFamily: "Qwen",
            minRAMGB: 48,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q8_0",
                reasoningOff: true
            ),
            notes: "Qwen3-32B Q8 on 64GB Max — ~12 tok/s, 32K context fits comfortably"
        ),

        DeviceModelProfile(
            deviceClass: .maxDesktop,
            maxRAMGB: 48,
            params: InferenceProfile(
                contextSize: 16384,
                kvCacheType: "q4_0",
                batchSize: 1024,
                flashAttn: true,
                mmap: true,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Max desktop 32GB — tighter memory, single slot"
        ),

        // Large models on Max 32GB: aggressive memory saving
        DeviceModelProfile(
            deviceClass: .maxDesktop,
            modelFamily: "Qwen",
            maxRAMGB: 48,
            params: InferenceProfile(
                contextSize: 8192,
                kvCacheType: "q4_0",
                reasoningOff: true
            ),
            notes: "Qwen 32B on 32GB Max — minimal context to fit"
        ),

        // ════════════════════════════════════════════════════════════════════
        // Pro Laptop (M*Pro, 16-48 GB) — mainstream power user
        // Memory bandwidth: ~200 GB/s (M2 Pro), ~300 GB/s (M3/M4 Pro)
        // 16GB M2 Pro: ~14 tok/s with 8B Q4 model, good for chat
        // ════════════════════════════════════════════════════════════════════

        DeviceModelProfile(
            deviceClass: .proLaptop,
            minRAMGB: 32,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q8_0",
                batchSize: 2048,
                flashAttn: true,
                mmap: true,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Pro 32GB+ — good context, single slot to conserve memory"
        ),

        DeviceModelProfile(
            deviceClass: .proLaptop,
            maxRAMGB: 32,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q4_0",
                batchSize: 1024,
                flashAttn: false,
                mmap: false,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Pro 16-18GB — q4 KV cache, 32K context fits with small models"
        ),

        // Hermes-8B Q4 on 16GB Pro: ~5GB model, plenty of room for 32K context
        DeviceModelProfile(
            deviceClass: .proLaptop,
            modelFamily: "Llama",
            maxRAMGB: 32,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q4_0"
            ),
            notes: "8B Llama/Hermes on 16GB Pro — small model, 32K context fits easily"
        ),

        DeviceModelProfile(
            deviceClass: .proLaptop,
            modelFamily: "Qwen",
            maxRAMGB: 32,
            params: InferenceProfile(
                contextSize: 32768,
                kvCacheType: "q4_0",
                reasoningOff: true
            ),
            notes: "Qwen 8B on 16GB Pro — fits 32K with q4 KV, reasoning off"
        ),

        DeviceModelProfile(
            deviceClass: .proLaptop,
            modelFamily: "Qwen",
            minRAMGB: 32,
            params: InferenceProfile(
                reasoningOff: true
            ),
            notes: "Qwen on 32GB+ Pro — reasoning off by default"
        ),

        // ════════════════════════════════════════════════════════════════════
        // Base Mac (M1/M2/M3/M4 base, 8-24 GB) — memory-constrained
        // ════════════════════════════════════════════════════════════════════

        DeviceModelProfile(
            deviceClass: .baseMac,
            minRAMGB: 16,
            params: InferenceProfile(
                contextSize: 16384,
                kvCacheType: "q4_0",
                batchSize: 1024,
                flashAttn: false,
                mmap: false,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Base Mac 16-24GB — moderate context, q4 KV to conserve memory"
        ),

        DeviceModelProfile(
            deviceClass: .baseMac,
            maxRAMGB: 16,
            params: InferenceProfile(
                contextSize: 4096,
                kvCacheType: "q4_0",
                batchSize: 512,
                flashAttn: false,
                mmap: false,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Base Mac 8GB — minimal context, smallest models only"
        ),

        // M3/M4 base can use flash attention (hardware support)
        DeviceModelProfile(
            deviceClass: .baseMac,
            minRAMGB: 16,
            params: InferenceProfile(
                flashAttn: true
            ),
            notes: "Override: M3/M4 base chips support flash attention well"
            // Note: resolver checks chip generation >= 3 before applying this
        ),

        // Small models on 16GB base Mac can afford more context
        DeviceModelProfile(
            deviceClass: .baseMac,
            modelID: "llama-3.2-1b-instruct-4bit",
            minRAMGB: 16,
            params: InferenceProfile(
                contextSize: 32768
            ),
            notes: "1B model on 16GB — tiny model, plenty of room for context"
        ),

        DeviceModelProfile(
            deviceClass: .baseMac,
            modelID: "llama-3.2-3b-instruct-4bit",
            minRAMGB: 16,
            params: InferenceProfile(
                contextSize: 16384
            ),
            notes: "3B model on 16GB — still small enough for decent context"
        ),

        DeviceModelProfile(
            deviceClass: .baseMac,
            modelFamily: "Qwen",
            params: InferenceProfile(
                reasoningOff: true
            ),
            notes: "Qwen on base Mac — always disable reasoning"
        ),

        // ════════════════════════════════════════════════════════════════════
        // Mobile (A-series, 4-16 GB) — very constrained
        // ════════════════════════════════════════════════════════════════════

        DeviceModelProfile(
            deviceClass: .mobile,
            params: InferenceProfile(
                contextSize: 4096,
                kvCacheType: "q4_0",
                batchSize: 256,
                flashAttn: false,
                mmap: false,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Mobile default — minimal everything"
        ),

        // ════════════════════════════════════════════════════════════════════
        // Other (NVIDIA, AMD, Intel, ARM) — conservative defaults
        // ════════════════════════════════════════════════════════════════════

        DeviceModelProfile(
            deviceClass: .other,
            params: InferenceProfile(
                contextSize: 8192,
                kvCacheType: "q8_0",
                batchSize: 1024,
                flashAttn: false,
                mmap: true,
                parallelSlots: 1,
                gpuLayers: 999
            ),
            notes: "Non-Apple default — conservative, mmap for large models"
        ),
    ]
}

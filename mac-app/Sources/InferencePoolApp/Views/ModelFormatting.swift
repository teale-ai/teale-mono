import Foundation

/// Clean up a raw model ID (file path or HF repo) into a human-friendly display name.
/// "/Users/foo/Qwen3-235B-A22B-Q8_0-00001-of-00006.gguf" → "Qwen3 235B A22B"
/// "mlx-community/Qwen3-32B-4bit" → "Qwen3 32B 4bit"
/// "Hermes-3-Llama-3.1-8B.Q4_K_M.gguf" → "Hermes 3 Llama 3.1 8B"
func cleanModelDisplayName(_ modelID: String) -> String {
    // Take filename only (after last /)
    var name = modelID.components(separatedBy: "/").last ?? modelID

    // Strip .gguf extension
    if name.hasSuffix(".gguf") {
        name = String(name.dropLast(5))
    }

    // Strip split-file suffixes like "-00001-of-00006"
    if let range = name.range(of: #"-\d{3,}-of-\d{3,}"#, options: .regularExpression) {
        name.removeSubrange(range)
    }

    // Strip quantization suffixes (Q4_K_M, Q8_0, etc.) — pattern: dot or dash followed by Q/q then digits
    if let range = name.range(of: #"[._-][Qq]\d[._]\w*$"#, options: .regularExpression) {
        name.removeSubrange(range)
    }

    // Replace hyphens/underscores with spaces for readability
    name = name.replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")

    // Collapse multiple spaces
    while name.contains("  ") {
        name = name.replacingOccurrences(of: "  ", with: " ")
    }

    return name.trimmingCharacters(in: .whitespaces)
}

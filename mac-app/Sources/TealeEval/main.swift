// teale-eval - KV-cache quantization eval harness.
//
// Greedy-decodes a fixed prompt set with the baseline (unquantized KV
// cache) and with 8-bit KV quantization, then reports per-prompt output
// equality, first-divergence position, and speed for both configs. The
// ship gate for kvBits:8 (Taylor's call, Sep 5 2026): outputs must hold
// up under this harness; any degradation gets reported, not shipped.
//
// Usage: teale-eval [model-id]   (default: mlx-community/Qwen3-0.6B-4bit)

import Foundation
import MLX
import MLXInference
import MLXLLM
import MLXLMCommon

final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct PromptResult: Codable {
    let prompt: String
    let baselineText: String
    let quantizedText: String
    let identical: Bool
    let firstDivergenceChar: Int?
    let baselineTPS: Double
    let quantizedTPS: Double
    let baselinePromptTPS: Double
    let quantizedPromptTPS: Double
    let tokens: Int
}

struct EvalReport: Codable {
    let model: String
    let kvBits: Int
    let maxTokens: Int
    let promptCount: Int
    let identicalCount: Int
    let meanBaselineTPS: Double
    let meanQuantizedTPS: Double
    let speedupPct: Double
    let results: [PromptResult]
}

let prompts: [String] = [
    "Explain photosynthesis in two sentences.",
    "Write a haiku about distributed computing.",
    "What is the capital of Australia and why is it not Sydney?",
    "List five uses for a paperclip.",
    "Summarize the plot of Romeo and Juliet in three sentences.",
    "What is 17 * 23? Show your reasoning.",
    "Write a Python function that reverses a linked list.",
    "Explain the difference between TCP and UDP to a ten-year-old.",
    "Give me a recipe for pancakes using only six ingredients.",
    "What are the main causes of World War I? Be concise.",
    "Translate 'the quick brown fox jumps over the lazy dog' into French, German, and Spanish.",
    "Write a one-paragraph product description for a smart water bottle.",
    "Is a hot dog a sandwich? Argue both sides briefly.",
    "Explain what an API is using a restaurant analogy.",
    "What would happen if the Moon suddenly doubled in mass?",
    "Write SQL to find the second-highest salary from an employees table.",
]

func runConfig(
    container: ModelContainer,
    lmInput: LMInput,
    kvBits: Int?,
    maxTokens: Int
) async throws -> (text: String, info: GenerateCompletionInfo?) {
    var parameters = GenerateParameters(temperature: 0)
    parameters.maxTokens = maxTokens
    parameters.kvBits = kvBits
    parameters.quantizedKVStart = 0
    let inputBox = UncheckedSendableBox(lmInput)
    return try await container.perform { context in
        let cache = context.model.newCache(parameters: parameters)
        let stream = try MLXLMCommon.generate(
            input: inputBox.value,
            cache: cache,
            parameters: parameters,
            context: context
        )
        var text = ""
        var info: GenerateCompletionInfo? = nil
        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                text += chunk
            case .info(let completionInfo):
                info = completionInfo
            default:
                break
            }
        }
        return (text, info)
    }
}

func firstDivergence(_ a: String, _ b: String) -> Int? {
    if a == b { return nil }
    let ac = Array(a), bc = Array(b)
    let limit = min(ac.count, bc.count)
    for i in 0..<limit where ac[i] != bc[i] { return i }
    return limit
}

let args = CommandLine.arguments
let modelId = args.count > 1 ? args[1] : "mlx-community/Qwen3-0.6B-4bit"
let maxTokens = 128
let kvBits = 8

print("[teale-eval] loading \(modelId)")
let container = try await LLMModelFactory.shared.loadContainer(
    from: HFDownloader(),
    using: HFTokenizerLoader(),
    configuration: ModelConfiguration(id: modelId)
) { progress in
    print(String(format: "[teale-eval] download %.0f%%", progress.fractionCompleted * 100))
}

var results: [PromptResult] = []
for (index, prompt) in prompts.enumerated() {
    let messages: [MLXLMCommon.Message] = [
        ["role": "user" as any Sendable, "content": prompt as any Sendable]
    ]
    let lmInput = try await container.prepare(input: UserInput(messages: messages))

    let baseline = try await runConfig(
        container: container, lmInput: lmInput, kvBits: nil, maxTokens: maxTokens)
    let quantized = try await runConfig(
        container: container, lmInput: lmInput, kvBits: kvBits, maxTokens: maxTokens)

    let result = PromptResult(
        prompt: prompt,
        baselineText: baseline.text,
        quantizedText: quantized.text,
        identical: baseline.text == quantized.text,
        firstDivergenceChar: firstDivergence(baseline.text, quantized.text),
        baselineTPS: baseline.info?.tokensPerSecond ?? 0,
        quantizedTPS: quantized.info?.tokensPerSecond ?? 0,
        baselinePromptTPS: baseline.info?.promptTokensPerSecond ?? 0,
        quantizedPromptTPS: quantized.info?.promptTokensPerSecond ?? 0,
        tokens: baseline.info?.generationTokenCount ?? 0
    )
    results.append(result)
    print(
        "[teale-eval] \(index + 1)/\(prompts.count) identical=\(result.identical) "
            + "tps \(String(format: "%.1f", result.baselineTPS))->\(String(format: "%.1f", result.quantizedTPS))"
    )
}

let identicalCount = results.filter(\.identical).count
let meanBaseline = results.map(\.baselineTPS).reduce(0, +) / Double(results.count)
let meanQuantized = results.map(\.quantizedTPS).reduce(0, +) / Double(results.count)
let report = EvalReport(
    model: modelId,
    kvBits: kvBits,
    maxTokens: maxTokens,
    promptCount: results.count,
    identicalCount: identicalCount,
    meanBaselineTPS: meanBaseline,
    meanQuantizedTPS: meanQuantized,
    speedupPct: (meanQuantized - meanBaseline) / meanBaseline * 100.0,
    results: results
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(report)
let outPath = "eval-results.json"
try data.write(to: URL(fileURLWithPath: outPath))
print("[teale-eval] identical \(identicalCount)/\(results.count), mean tps "
    + "\(String(format: "%.1f", meanBaseline)) -> \(String(format: "%.1f", meanQuantized)) "
    + "(\(String(format: "%+.1f", report.speedupPct))%), wrote \(outPath)")

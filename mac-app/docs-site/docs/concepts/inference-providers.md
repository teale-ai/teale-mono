# Inference Providers

Every inference backend in Teale implements the same `InferenceProvider` protocol, making the source of inference transparent to the caller.

## The InferenceProvider protocol

```swift
public protocol InferenceProvider: Sendable {
    var status: EngineStatus { get async }
    var loadedModel: ModelDescriptor? { get async }
    func loadModel(_ descriptor: ModelDescriptor) async throws
    func unloadModel() async
    func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error>
    func generateFull(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}
```

Any type that conforms to this protocol can serve as an inference source. The `InferenceEngineManager` accepts `any InferenceProvider` and can swap backends at runtime.

## MLXProvider

On-device inference using Apple's MLX framework, optimized for Apple Silicon unified memory.

- **Format:** HuggingFace models, typically quantized (4-bit, 8-bit)
- **Strengths:** Native Apple Silicon optimization, low memory overhead, Neural Engine access
- **Best for:** Interactive chat on M-series Macs and iPhones
- **Module:** `MLXInference` (wraps mlx-swift and mlx-swift-lm)

MLXProvider downloads models from HuggingFace Hub, manages a local cache, and handles tokenization via swift-transformers. It streams tokens as they are generated.

## LlamaCppProvider

Wraps llama.cpp as a subprocess, communicating over HTTP.

- **Format:** GGUF (llama.cpp's native format), supports 80+ model architectures
- **Strengths:** Often 6x throughput compared to MLX on the same hardware, broad model compatibility
- **Best for:** High-throughput inference, non-Apple platforms via teale-node
- **Module:** `LlamaCppKit`

LlamaCppKit manages the llama.cpp server process lifecycle, forwards requests via HTTP, and translates responses into the standard `ChatCompletionChunk` stream.

## ClusterProvider

Routes requests to LAN peers that have the requested model loaded and lower current load.

- **Discovery:** Bonjour/mDNS on the local network
- **Transport:** NWConnection (TCP) with custom NWProtocolFramer
- **Routing logic:** Prefers peers with the model already loaded, lowest active request count, and highest hardware capability score
- **Fallback:** If no suitable LAN peer is found, passes the request down the chain
- **Module:** `ClusterKit`

ClusterProvider is transparent --- the caller does not know whether inference ran locally or on a LAN peer. See [Networking](networking.md) for protocol details.

## WANProvider

Routes requests to peers across the internet via relay signaling or direct QUIC connections.

- **Discovery:** WebSocket relay at `wss://relay.teale.com/ws`
- **Transport:** QUIC (Network.framework) for direct P2P, with relay fallback
- **NAT traversal:** STUN for public endpoint discovery, hole-punching for direct connections
- **Encryption:** Noise protocol (E2E), Ed25519 identity
- **Module:** `WANKit`

WANProvider first attempts a direct QUIC connection. If NAT prevents it, traffic routes through the relay. In both cases, end-to-end encryption ensures the relay cannot read request or response data. See [Security Model](security-model.md) for details.

## Compiler (Mixture of Models)

For complex queries that benefit from multiple specialized models working in parallel.

- **Analysis:** `RequestAnalyzer` determines whether decomposition would improve quality
- **Decomposition:** `TaskDecomposer` breaks the request into sub-tasks with dependency tracking
- **Assignment:** `ModelSelector` assigns each sub-task to the best-fit model based on category affinity scores
- **Execution:** `FanOutExecutor` runs sub-tasks in parallel across devices, respecting dependency ordering
- **Synthesis:** `ResponseSynthesizer` combines sub-task results into a coherent response
- **Module:** `CompilerKit`

The Compiler supports three plans: passthrough (simple requests), compiled (decompose and fan-out), and compete (send to N models, pick the best). See [Mixture of Models](mixture-of-models.md) for the full breakdown.

## CreditAwareProvider

Middleware that wraps any provider and enforces the credit economy.

- Checks the caller's balance before forwarding a request
- Tracks token counts during streaming
- Debits the caller and credits the provider after completion
- Rejects requests if the balance is below the minimum ($0.0001 for remote inference)
- **Module:** `CreditKit`

CreditAwareProvider is not a standalone backend --- it wraps another provider and adds economic enforcement. See [Credit Economy](credit-economy.md) for pricing details.

## RequestScheduler

Schedules incoming requests using Weighted Fair Queuing (WFQ).

- **PTN traffic:** 70% weight. Private TealeNet members get priority access.
- **WWTN traffic:** 30% weight. Public network requests fill remaining capacity.
- **Zero waste:** If one queue is empty, the other gets 100% of capacity.

The scheduler ensures that PTN members who pay fixed rates always get reliable performance, while WWTN traffic fills idle capacity at market rates.

## Provider chain in practice

When you type a message in the Teale chat:

1. The request hits `InferenceEngineManager`, which holds the active provider chain.
2. `CreditAwareProvider` checks your balance (skipped for local inference).
3. `MLXProvider` attempts local generation. If the model is loaded and the device is not throttled, it handles the request.
4. If local fails, `LlamaCppProvider` tries. If llama.cpp has the model, it generates.
5. If no local provider can handle it, `ClusterProvider` checks LAN peers.
6. If no LAN peer is available, `WANProvider` finds a WAN peer through the relay.
7. For multi-model requests, the `Compiler` decomposes and fans out across available providers.

The response streams back through the same chain, token by token, to the UI.

## Related pages

- [How Teale Works](how-teale-works.md) --- high-level architecture
- [Networking](networking.md) --- transport protocols for cluster and WAN
- [Credit Economy](credit-economy.md) --- pricing and the CreditAwareProvider
- [Mixture of Models](mixture-of-models.md) --- CompilerKit deep dive

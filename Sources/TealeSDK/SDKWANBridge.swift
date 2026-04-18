import Foundation
import SharedTypes
import WANKit
import CreditKit
import ClusterKit

// MARK: - SDK WAN Bridge

/// Connects the WAN network to local inference, handling incoming requests
/// and recording credits earned for the developer's wallet.
actor SDKWANBridge {
    private let wanManager: WANManager
    private let inferenceProvider: any InferenceProvider
    private let wallet: USDCWallet
    private let resourceGovernor: ResourceGovernor
    private let earningsReporter: EarningsReporter
    private var currentModel: ModelDescriptor?

    private var totalRequestsServed: Int = 0
    private var totalTokensGenerated: Int = 0

    init(
        wanManager: WANManager,
        inferenceProvider: any InferenceProvider,
        wallet: USDCWallet,
        resourceGovernor: ResourceGovernor,
        earningsReporter: EarningsReporter
    ) {
        self.wanManager = wanManager
        self.inferenceProvider = inferenceProvider
        self.wallet = wallet
        self.resourceGovernor = resourceGovernor
        self.earningsReporter = earningsReporter
    }

    func setCurrentModel(_ model: ModelDescriptor) {
        currentModel = model
    }

    /// Wire up the WAN manager to handle incoming inference requests
    func start() async {
        wanManager.onInferenceRequest = { [weak self] payload, connection in
            guard let self = self else { return }
            await self.handleInferenceRequest(payload, connection: connection)
        }
    }

    func stop() async {
        wanManager.onInferenceRequest = nil
    }

    var stats: (requests: Int, tokens: Int) {
        (totalRequestsServed, totalTokensGenerated)
    }

    // MARK: - Request Handling

    private func handleInferenceRequest(
        _ payload: InferenceRequestPayload,
        connection: WANTransportConnection
    ) async {
        // Check if we should accept work
        guard await resourceGovernor.shouldAcceptWork() else {
            let error = ClusterMessage.inferenceError(
                InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: "Device busy or resource-constrained"
                )
            )
            try? await connection.send(error)
            return
        }

        await resourceGovernor.requestStarted()
        defer { Task { await resourceGovernor.requestCompleted() } }

        var tokenCount = 0

        do {
            if payload.streaming {
                let stream = inferenceProvider.generate(request: payload.request)
                for try await chunk in stream {
                    tokenCount += 1
                    let chunkMessage = ClusterMessage.inferenceChunk(
                        InferenceChunkPayload(
                            requestID: payload.requestID,
                            chunk: chunk
                        )
                    )
                    try await connection.send(chunkMessage)
                }
            } else {
                let response = try await inferenceProvider.generateFull(request: payload.request)
                // Estimate token count from response content length
                if let content = response.choices.first?.message.content {
                    tokenCount = content.count / 4  // rough estimate
                }
            }

            // Send completion
            let complete = ClusterMessage.inferenceComplete(
                InferenceCompletePayload(requestID: payload.requestID)
            )
            try? await connection.send(complete)

            totalRequestsServed += 1
            totalTokensGenerated += tokenCount

            // Record credits earned
            if let model = currentModel {
                await wallet.recordEarning(tokens: tokenCount, model: model)
                await earningsReporter.reportEarning(
                    requestID: payload.requestID,
                    tokensGenerated: tokenCount,
                    modelID: model.id,
                    creditsEarned: InferencePricing.earning(tokenCount: tokenCount, model: model),
                    peerNodeID: nil
                )
            }
        } catch {
            let errorMessage = ClusterMessage.inferenceError(
                InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: error.localizedDescription
                )
            )
            try? await connection.send(errorMessage)
        }
    }
}

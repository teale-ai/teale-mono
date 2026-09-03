import Foundation
import ClusterKit
import CryptoKit
import PINKit
import SharedTypes
import WANKit

/// Mac demand path for Private Inference Networks: pick a provider
/// (gateway-scheduled when online, cached-netmap fallback offline), dial it
/// directly over the encrypted WAN transport, stream the completion.
/// Mirrors node/src/pin/client.rs — the prompt only ever rides the
/// device-to-device Noise session.
public enum PINChatClient {

    /// Total providers tried per request (1 + 2 cascades), matching the node.
    private static let maxAttempts = 3
    private static let scheduleTimeoutSeconds: UInt64 = 6
    private static let endpointDialTimeoutSeconds: UInt64 = 12
    private static let responseTimeoutSeconds: UInt64 = 75

    public enum PINChatError: Error, CustomStringConvertible {
        case noProviders(String)
        case allAttemptsFailed(String)

        public var description: String {
            switch self {
            case .noProviders(let model):
                return "no private-network providers available for model \(model)"
            case .allAttemptsFailed(let last):
                return "all private-network providers failed: \(last)"
            }
        }
    }

    struct Candidate {
        let pinId: String
        let member: PinNetmapMember
    }

    /// Stream a completion from a PIN provider as ChatCompletionChunk values.
    /// Ends normally on inferenceComplete; throws on terminal errors.
    public static func stream(
        service: PINService,
        identity: WANNodeIdentity,
        model: String,
        request: ChatCompletionRequest,
        connectionForNode: @escaping @Sendable (String) async -> WANTransportConnection? = { _ in nil }
    ) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        var tried: [String] = []
        var lastError = "no candidates"

        for _ in 0..<maxAttempts {
            guard let candidate = await nextCandidate(
                service: service, model: model, excluding: tried, selfNodeID: identity.nodeID)
            else { break }
            tried.append(candidate.member.nodePubkey)
            do {
                return try await attempt(
                    candidate: candidate,
                    identity: identity,
                    model: model,
                    request: request,
                    connectionForNode: connectionForNode
                )
            } catch {
                lastError = String(describing: error)
            }
        }
        if tried.isEmpty {
            throw PINChatError.noProviders(model)
        }
        throw PINChatError.allAttemptsFailed(lastError)
    }

    private static func nextCandidate(
        service: PINService, model: String, excluding: [String], selfNodeID: String
    ) async -> Candidate? {
        // Prefer the current signed netmap. This keeps prompt-bearing
        // requests off the gateway hot path and makes LAN/offline PINs usable.
        if let cached = await service.manager.servingPeersForModel(model)
            .filter({ !excluding.contains($0.1.nodePubkey) })
            .map({ Candidate(pinId: $0.0, member: $0.1) })
            .first {
            log("selected cached PIN provider \(cached.member.displayName ?? cached.member.nodePubkey) for \(model)")
            return cached
        }

        // Gateway fallback: useful when local cache is stale, but bounded so
        // the local SSE endpoint can fail fast instead of appearing hung.
        for pin in await service.manager.snapshot() where pin.membership == "active" {
            guard let netmap = pin.netmap?.netmap else { continue }
            // The gateway intentionally allows self-selection ("Requester's
            // own device may serve itself"), but Noise-dialing our own static
            // key hangs until the dial timeout. Skip self here; the local
            // endpoint short-circuits self-provision before we get here.
            if let choice = try? await scheduleWithTimeout(
                service: service, pinId: pin.pinId, model: model,
                excluding: excluding + [selfNodeID]),
                choice.nodePubkey != selfNodeID,
                let member = netmap.members.first(where: { $0.deviceId == choice.deviceId }) {
                log("selected gateway PIN provider \(member.displayName ?? member.nodePubkey) for \(model)")
                return Candidate(pinId: pin.pinId, member: member)
            }
        }
        log("no PIN provider candidate for \(model)")
        return nil
    }

    private static func scheduleWithTimeout(
        service: PINService, pinId: String, model: String, excluding: [String]
    ) async throws -> PINManager.ScheduleChoice {
        try await withThrowingTaskGroup(of: PINManager.ScheduleChoice.self) { group in
            group.addTask {
                try await service.manager.schedule(
                    pinId: pinId, model: model, exclude: excluding)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: scheduleTimeoutSeconds * 1_000_000_000)
                throw PINChatError.allAttemptsFailed("gateway schedule timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func attempt(
        candidate: Candidate,
        identity: WANNodeIdentity,
        model: String,
        request: ChatCompletionRequest,
        connectionForNode: @escaping @Sendable (String) async -> WANTransportConnection?
    ) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        guard let wgKeyData = Data(hexString: candidate.member.wgPubkey),
            let wgKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: wgKeyData)
        else {
            throw PINChatError.allAttemptsFailed("provider has no usable wg key")
        }
        // Dial ladder: lan endpoints first, then reflexive.
        let ordered = candidate.member.endpoints.filter { $0.kind == "lan" }
            + candidate.member.endpoints.filter { $0.kind == "reflexive" }
        guard !ordered.isEmpty else {
            throw PINChatError.allAttemptsFailed("provider advertises no endpoints")
        }

        let transport: WANTransportConnection
        let ownsTransport: Bool
        if let existing = await connectionForNode(candidate.member.nodePubkey) {
            log("using existing WAN connection to \(candidate.member.displayName ?? candidate.member.nodePubkey)")
            transport = existing
            ownsTransport = false
        } else {
            var connection: WireGuardPeerConnection?
            for endpoint in ordered {
                let parts = endpoint.addr.split(separator: ":")
                guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
                let dialed = WireGuardTransport.connect(
                    to: String(parts[0]),
                    port: port,
                    remoteNodeID: candidate.member.nodePubkey,
                    remoteWGPublicKey: wgKey,
                    localIdentity: identity
                )
                log("dialing \(candidate.member.displayName ?? candidate.member.nodePubkey) at \(endpoint.addr)")
                await startWithTimeout(dialed)
                if case .connected = await dialed.connectionState {
                    connection = dialed
                    break
                }
                await dialed.cancel()
            }
            guard let connection else {
                throw PINChatError.allAttemptsFailed("all endpoints undialable")
            }
            transport = .direct(connection)
            ownsTransport = true
        }

        var payload = request
        payload.model = model
        let requestID = UUID()
        let messages = await transport.incomingMessages
        log("sending PIN inference request \(requestID) model=\(model) provider=\(candidate.member.displayName ?? candidate.member.nodePubkey)")
        try await transport.send(
            .inferenceRequest(InferenceRequestPayload(requestID: requestID, request: payload)))

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    if ownsTransport {
                        Task { await transport.cancel() }
                    }
                }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await Task.sleep(
                                nanoseconds: responseTimeoutSeconds * 1_000_000_000)
                            throw PINChatError.allAttemptsFailed("provider response timed out")
                        }
                        group.addTask {
                            for await message in messages {
                                switch message {
                                case .inferenceChunk(let chunk) where chunk.requestID == requestID:
                                    log("received PIN inference chunk \(requestID)")
                                    continuation.yield(chunk.chunk)
                                case .inferenceComplete(let done) where done.requestID == requestID:
                                    log("received PIN inference complete \(done.requestID)")
                                    continuation.finish()
                                    return
                                case .inferenceError(let error) where error.requestID == requestID:
                                    log("received PIN inference error \(requestID): \(error.errorMessage)")
                                    throw PINChatError.allAttemptsFailed(error.errorMessage)
                                default:
                                    break
                                }
                            }
                            throw PINChatError.allAttemptsFailed("provider disconnected")
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func startWithTimeout(_ connection: WireGuardPeerConnection) async {
        let startTask = Task { await connection.start() }
        for _ in 0..<Int(endpointDialTimeoutSeconds * 4) {
            switch await connection.connectionState {
            case .connected, .failed, .disconnected:
                startTask.cancel()
                return
            case .connecting, .waiting:
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await connection.cancel()
        startTask.cancel()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[PINChat] \(message)\n".utf8))
    }
}

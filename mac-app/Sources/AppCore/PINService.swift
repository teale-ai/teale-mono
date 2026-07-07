import Foundation
import PINKit
import GatewayKit
import WANKit

/// Owns the Mac app's PIN control-plane runtime: the PINKit manager, the
/// 60-second sync loop, and usage flushing. Serving-side request mapping is
/// installed by AppState (WAN inbound requests → PIN WFQ lane + usage).
public final class PINService: @unchecked Sendable {

    struct AuthAdapter: PINGatewayAuth {
        let deviceID: String
        let client: GatewayAuthClient
        func bearer() async throws -> String { try await client.bearer() }
    }

    public let manager: PINManager
    private var syncTask: Task<Void, Never>?

    public init(gatewayBaseURL: URL) throws {
        let identity = try AppState.canonicalWANIdentity()
        let wgPubkeyHex = identity.keyAgreementPublicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Teale/pin", isDirectory: true)
        manager = PINManager(
            gatewayBaseURL: gatewayBaseURL,
            auth: AuthAdapter(
                deviceID: GatewayIdentity.shared.deviceID,
                client: GatewayAuthClient(baseURL: gatewayBaseURL)
            ),
            wgPubkeyHex: wgPubkeyHex,
            dataDir: support
        )
    }

    /// Start the periodic control-plane sync. Providers are polled each
    /// tick so endpoints/models stay current.
    public func start(
        endpoints: @escaping @Sendable () async -> [PinEndpoint],
        loadedModels: @escaping @Sendable () async -> [String],
        reconcile: @escaping @Sendable () async -> Void = {}
    ) {
        guard syncTask == nil else { return }
        syncTask = Task { [manager] in
            while !Task.isCancelled {
                let currentEndpoints = await endpoints()
                let models = await loadedModels()
                do {
                    _ = try await manager.syncOnce(
                        endpoints: currentEndpoints, loadedModels: models)
                } catch {
                    // Offline is normal; cached netmaps keep the LAN working.
                }
                // Execute any admin/modelrator model-policy pushes, then
                // report the results on the next sync tick.
                await reconcile()
                await manager.flushUsage()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    /// Reconcile every active network's desired loadout against local state,
    /// honoring the per-device remote-management opt-out, and record the
    /// per-model status for the next sync advertisement. Mirrors
    /// node/src/pin/runtime.rs `reconcile_policy`.
    public func reconcilePolicy(
        loadedModels: @Sendable () async -> [String],
        downloadedModels: @Sendable () async -> [String],
        ensureDownload: @Sendable (String) async -> Result<Void, Error>,
        ensureLoaded: @Sendable (String) async -> Result<Void, Error>
    ) async {
        let optedOut = await !manager.settings().allowRemoteModels
        var results: [(String, String, String, String?)] = []
        for pin in await manager.snapshot() where pin.membership == "active" {
            for entry in pin.modelPolicy {
                guard let modelId = entry["modelId"] as? String,
                    let desired = entry["desiredState"] as? String
                else { continue }
                if optedOut {
                    results.append((pin.pinId, modelId, "opted_out", nil))
                    continue
                }
                let loaded = await loadedModels()
                let downloaded = await downloadedModels()
                let isLoaded = loaded.contains(modelId)
                let isDownloaded = isLoaded || downloaded.contains(modelId)
                switch desired {
                case "loaded" where isLoaded:
                    results.append((pin.pinId, modelId, "loaded", nil))
                case "loaded":
                    if !isDownloaded, case .failure(let err) = await ensureDownload(modelId) {
                        results.append((pin.pinId, modelId, "downloading", "\(err)"))
                    } else if case .failure(let err) = await ensureLoaded(modelId) {
                        results.append((pin.pinId, modelId, "error", "\(err)"))
                    } else {
                        results.append((pin.pinId, modelId, "loaded", nil))
                    }
                case "downloaded" where isDownloaded:
                    results.append((pin.pinId, modelId, "downloaded", nil))
                case "downloaded":
                    if case .failure(let err) = await ensureDownload(modelId) {
                        results.append((pin.pinId, modelId, "downloading", "\(err)"))
                    } else {
                        results.append((pin.pinId, modelId, "downloaded", nil))
                    }
                default:
                    // v1 never force-unloads; report reality.
                    let state = isLoaded ? "loaded" : (isDownloaded ? "downloaded" : "absent")
                    results.append((pin.pinId, modelId, state, nil))
                }
            }
        }
        await manager.recordPolicyStatus(results)
    }

    public func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Build the /v1/app/pins overview payload (same shape as the node).
    public func overviewJSON() async throws -> Data {
        let snapshot = await manager.snapshot()
        let staff = await manager.fetchStaffSummaries()
        let settings = await manager.settings()
        var networks: [[String: Any]] = []
        for pin in snapshot {
            var entry: [String: Any] = [
                "pinId": pin.pinId,
                "name": pin.name,
                "membership": pin.membership,
                "modelPolicy": pin.modelPolicy,
            ]
            if let signed = pin.netmap {
                entry["netmap"] = [
                    "netmap": signed.rawNetmapObject,
                    "gatewayPubkey": signed.gatewayPubkey,
                    "signature": signed.signature,
                ]
            }
            if let s = pin.settings { entry["settings"] = s }
            networks.append(entry)
        }
        let payload: [String: Any] = [
            "networks": networks,
            "staff": staff,
            "deviceId": GatewayIdentity.shared.deviceID,
            "wgPubkey": manager.wgPubkeyHex,
            "settings": [
                "allowRemoteModels": settings.allowRemoteModels,
                "dinPriorityEqual": settings.dinPriorityEqual,
                "dinContribute": settings.dinContribute,
            ],
            "pendingUsageBatches": await manager.pendingUsageBatches(),
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

import Foundation
import SharedTypes

// MARK: - Request Router

/// Routes inference requests to the best available node in the cluster
public struct RequestRouter: Sendable {

    public init() {}

    /// Decide where to route a request.
    /// Uses `request.groupID` as the org preference for group-first routing.
    public func route(
        request: ChatCompletionRequest,
        clusterManager: ClusterManager,
        localModel: ModelDescriptor?
    ) -> RouteDecision {
        route(
            request: request,
            clusterManager: clusterManager,
            localModel: localModel,
            requestOrganizationID: request.groupID,
            isExternalRequest: false
        )
    }

    /// Decide where to route a request with org-aware priority routing
    public func route(
        request: ChatCompletionRequest,
        clusterManager: ClusterManager,
        localModel: ModelDescriptor?,
        requestOrganizationID: String?,
        isExternalRequest: Bool
    ) -> RouteDecision {
        let requestedModel = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLocalModelID = localModel.flatMap { $0.openrouterId ?? $0.huggingFaceRepo }
        let modelID = requestedModel?.isEmpty == false ? requestedModel! : (effectiveLocalModelID ?? "")

        // For external (non-org) requests, check capacity reservation
        if isExternalRequest {
            let reservation = clusterManager.orgCapacityReservation
            let totalPeers = clusterManager.topology.connectedPeers.count
            let busyPeers = clusterManager.topology.connectedPeers.filter { $0.isGenerating }.count

            // If org peers are using more than (1 - reservation) of capacity, reject external
            if totalPeers > 0 {
                let utilization = Double(busyPeers) / Double(totalPeers)
                let externalAllocation = 1.0 - reservation
                if utilization >= externalAllocation {
                    return .capacityReserved
                }
            }
        }

        // First: check if any remote peer has the model loaded and is available
        if let bestPeer = clusterManager.topology.bestPeerForModel(modelID, preferringOrg: requestOrganizationID) {
            return .remote(peerID: bestPeer.id, peer: bestPeer)
        }

        // Second: use local only when it can actually satisfy the request.
        if let localModel {
            if let requestedModel {
                if modelIdentifiersMatch(localModel, requested: requestedModel) {
                    return .local
                }
            } else {
                return .local
            }
        }

        // Third: for implicit routing only, fall back to any peer with a loaded model.
        guard requestedModel == nil || requestedModel?.isEmpty == true else {
            return .noModelAvailable
        }

        let anyAvailablePeer = clusterManager.topology.connectedPeers
            .filter { !$0.isGenerating && $0.throttleLevel > 0 && !$0.loadedModels.isEmpty }
            .sorted { lhs, rhs in
                if lhs.activeRequestCount != rhs.activeRequestCount {
                    return lhs.activeRequestCount < rhs.activeRequestCount
                }
                return lhs.capabilityScore > rhs.capabilityScore
            }
            .first

        if let peer = anyAvailablePeer {
            return .remote(peerID: peer.id, peer: peer)
        }

        // No model available anywhere
        return .noModelAvailable
    }

    private func modelIdentifiersMatch(_ descriptor: ModelDescriptor, requested: String) -> Bool {
        let query = normalizeModelID(requested)
        guard !query.isEmpty else { return false }
        let candidates = [descriptor.id, descriptor.huggingFaceRepo, descriptor.openrouterId ?? ""]
            .filter { !$0.isEmpty }
            .map(normalizeModelID)
        let queryTail = query.split(separator: "/").last.map(String.init) ?? query
        for candidate in candidates {
            if candidate == query { return true }
            let candidateTail = candidate.split(separator: "/").last.map(String.init) ?? candidate
            if candidateTail == queryTail { return true }
        }
        return false
    }

    private func normalizeModelID(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}

// MARK: - Route Decision

public enum RouteDecision: Sendable {
    case local
    case remote(peerID: UUID, peer: PeerInfo)
    case noModelAvailable
    case capacityReserved
}

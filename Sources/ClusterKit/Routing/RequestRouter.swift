import Foundation
import SharedTypes

// MARK: - Request Router

/// Routes inference requests to the best available node in the cluster
public struct RequestRouter: Sendable {

    public init() {}

    /// Decide where to route a request
    public func route(
        request: ChatCompletionRequest,
        clusterManager: ClusterManager,
        localModelLoaded: String?
    ) -> RouteDecision {
        route(
            request: request,
            clusterManager: clusterManager,
            localModelLoaded: localModelLoaded,
            requestOrganizationID: nil,
            isExternalRequest: false
        )
    }

    /// Decide where to route a request with org-aware priority routing
    public func route(
        request: ChatCompletionRequest,
        clusterManager: ClusterManager,
        localModelLoaded: String?,
        requestOrganizationID: String?,
        isExternalRequest: Bool
    ) -> RouteDecision {
        let modelID = request.model ?? localModelLoaded ?? ""

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

        // Second: if local model is loaded, use local
        if localModelLoaded != nil {
            return .local
        }

        // Third: check if any remote peer has any model loaded (prefer least loaded)
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
}

// MARK: - Route Decision

public enum RouteDecision: Sendable {
    case local
    case remote(peerID: UUID, peer: PeerInfo)
    case noModelAvailable
    case capacityReserved
}

import Foundation

// MARK: - PTN (Private TealeNet) Types

/// Role within a Private TealeNet.
public enum PTNRole: String, Codable, Sendable {
    case admin      // Can invite, revoke, manage pricing
    case provider   // Can serve inference to PTN members
    case consumer   // Can request inference from PTN members
}

/// Lightweight PTN identifier for broadcasting in discovery/capabilities.
public struct PTNIdentifier: Codable, Sendable, Hashable, Identifiable {
    public var id: String { ptnID }
    public var ptnID: String    // CA public key hex (64 chars)
    public var ptnName: String  // Human-readable name

    public init(ptnID: String, ptnName: String) {
        self.ptnID = ptnID
        self.ptnName = ptnName
    }
}

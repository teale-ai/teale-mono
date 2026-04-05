import Foundation

// MARK: - Agent Transport Protocol

/// Protocol for sending/receiving agent messages over the network.
/// The app layer implements this using ClusterKit (LAN) or WANKit (WAN).
public protocol AgentTransport: Sendable {
    func send(data: Data, to nodeID: String) async throws
}

// MARK: - Agent Transport Message

/// Wrapper for transporting AgentMessage as serialized data over the network.
public struct AgentTransportMessage: Codable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(message: AgentMessage) throws {
        self.data = try JSONEncoder().encode(message)
    }

    public func decode() throws -> AgentMessage {
        try JSONDecoder().decode(AgentMessage.self, from: data)
    }
}

// MARK: - Message Signer Protocol

/// Protocol for signing and verifying agent messages.
/// The app layer implements this using the WANNodeIdentity Ed25519 keypair.
public protocol AgentMessageSigner: Sendable {
    func sign(_ data: Data) throws -> Data
    func verify(signature: Data, data: Data, fromNodeID: String) throws -> Bool
}

// MARK: - Agent Router

public actor AgentRouter {
    private var transport: AgentTransport?
    private var signer: AgentMessageSigner?
    private var messageHandler: (@Sendable (AgentMessage) async -> Void)?

    public init() {}

    // MARK: - Configuration

    public func configure(transport: AgentTransport, signer: AgentMessageSigner? = nil) {
        self.transport = transport
        self.signer = signer
    }

    public func onMessageReceived(_ handler: @escaping @Sendable (AgentMessage) async -> Void) {
        self.messageHandler = handler
    }

    // MARK: - Sending

    public func send(message: AgentMessage, to nodeID: String) async throws {
        guard let transport = transport else {
            throw AgentError.transportNotAvailable
        }

        var signed = message
        if let signer = signer {
            let signingData = try message.signingData()
            signed.signature = try signer.sign(signingData)
        }

        let envelope = try AgentTransportMessage(message: signed)
        let data = try JSONEncoder().encode(envelope)
        try await transport.send(data: data, to: nodeID)
    }

    // MARK: - Receiving

    /// Called by the transport layer when raw data is received.
    public func handleIncomingData(_ data: Data) async throws {
        let envelope = try JSONDecoder().decode(AgentTransportMessage.self, from: data)
        let message = try envelope.decode()

        // Verify signature if signer is configured
        if let signer = signer, let signature = message.signature {
            let signingData = try message.signingData()
            let valid = try signer.verify(signature: signature, data: signingData, fromNodeID: message.fromAgentID)
            if !valid {
                throw AgentError.signatureVerificationFailed
            }
        }

        await messageHandler?(message)
    }
}

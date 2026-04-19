import Foundation
import Network
import CryptoKit
import ClusterKit

// MARK: - WireGuard Peer Connection (Noise-encrypted UDP transport)

public actor WireGuardPeerConnection {
    public nonisolated(unsafe) var remoteNodeID: String
    public private(set) var isReady: Bool = false
    public private(set) var connectionState: WANConnectionState = .connecting

    /// The remote peer's WG public key, revealed during the Noise handshake (responder path).
    public private(set) var remoteWGPublicKeyRevealed: Curve25519.KeyAgreement.PublicKey?

    // UDP connection via Network.framework
    private let udpConnection: NWConnection
    private let localIdentity: WANNodeIdentity
    private let remoteWGPublicKey: Curve25519.KeyAgreement.PublicKey?
    private let role: NoiseHandshake.Role

    // Noise session (established after handshake)
    private var noiseSession: NoiseSession?

    // Message stream — broadcast to all subscribers
    private var subscribers: [UUID: AsyncStream<ClusterMessage>.Continuation] = [:]

    // Fragment reassembly
    private var fragments: [UInt32: FragmentBuffer] = [:]

    // NAT keepalive
    private var lastSendTime: Date = Date()
    private var keepaliveTask: Task<Void, Never>?
    private static let keepaliveIntervalSeconds: TimeInterval = 20

    /// Create a connection as initiator (remote WG public key known from discovery).
    public init(
        connection: NWConnection,
        remoteNodeID: String,
        localIdentity: WANNodeIdentity,
        remoteWGPublicKey: Curve25519.KeyAgreement.PublicKey,
        role: NoiseHandshake.Role
    ) {
        self.udpConnection = connection
        self.remoteNodeID = remoteNodeID
        self.localIdentity = localIdentity
        self.remoteWGPublicKey = remoteWGPublicKey
        self.role = role
    }

    /// Create a connection as responder (remote identity unknown until handshake).
    public init(
        connection: NWConnection,
        localIdentity: WANNodeIdentity
    ) {
        self.udpConnection = connection
        self.remoteNodeID = "pending"
        self.localIdentity = localIdentity
        self.remoteWGPublicKey = nil
        self.role = .responder
    }

    // MARK: - Lifecycle

    /// Start the connection: perform Noise handshake, then begin receiving messages.
    public func start() async {
        udpConnection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateChange(state) }
        }

        udpConnection.start(queue: .global(qos: .userInitiated))
        await waitForReady()

        if case .failed = connectionState { return }

        // Perform Noise handshake
        do {
            try await performHandshake()
            receiveLoop()
            startKeepaliveLoop()
        } catch {
            connectionState = .failed("Handshake failed: \(error.localizedDescription)")
            for continuation in subscribers.values { continuation.finish() }
            subscribers.removeAll()
        }
    }

    /// Each caller gets a dedicated stream. All subscribers receive every message.
    public var incomingMessages: AsyncStream<ClusterMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ClusterMessage>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// Send a ClusterMessage to the peer (encrypted via Noise session).
    public func send(_ message: ClusterMessage) async throws {
        guard let session = noiseSession else {
            throw WANError.peerConnectionFailed("No active Noise session")
        }

        let jsonData = try JSONEncoder().encode(message)

        // Length-prefix the JSON (same format as ClusterKit)
        var length = UInt32(jsonData.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(jsonData)

        // Fragment if needed (max ~1200 bytes per UDP datagram payload after encryption overhead)
        let maxPayload = 1100
        if framed.count <= maxPayload {
            // Single packet: type 0x04 (transport data)
            let encrypted = try session.encrypt(framed)
            var packet = Data([0x04])  // transport data type
            packet.append(encrypted)
            try await sendUDP(packet)
        } else {
            // Fragment
            let fragmentID = UInt32.random(in: 0..<UInt32.max)
            let chunks = stride(from: 0, to: framed.count, by: maxPayload).map { start -> Data in
                let end = min(start + maxPayload, framed.count)
                return framed[start..<end]
            }
            let totalFragments = UInt16(chunks.count)

            for (index, chunk) in chunks.enumerated() {
                // Build fragment header inside encrypted payload
                var fragmentPayload = Data()
                withUnsafeBytes(of: fragmentID.bigEndian) { fragmentPayload.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt16(index).bigEndian) { fragmentPayload.append(contentsOf: $0) }
                withUnsafeBytes(of: totalFragments.bigEndian) { fragmentPayload.append(contentsOf: $0) }
                fragmentPayload.append(chunk)

                let encrypted = try session.encrypt(fragmentPayload)
                var packet = Data([0x05])  // transport fragment type
                packet.append(encrypted)
                try await sendUDP(packet)
            }
        }
    }

    /// Cancel the connection.
    public func cancel() {
        connectionState = .disconnected
        keepaliveTask?.cancel()
        keepaliveTask = nil
        udpConnection.cancel()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - NAT Keepalive

    private func startKeepaliveLoop() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepaliveIntervalSeconds) * 1_000_000_000)
                guard let self, case .connected = await self.connectionState else { return }

                let elapsed = Date().timeIntervalSince(await self.lastSendTime)
                if elapsed >= Self.keepaliveIntervalSeconds {
                    // Send an empty keepalive packet (type 0x03)
                    try? await self.sendUDP(Data([0x03]))
                    await self.updateLastSendTime()
                }
            }
        }
    }

    private func updateLastSendTime() {
        lastSendTime = Date()
    }

    // MARK: - Noise Handshake

    private func performHandshake() async throws {
        switch role {
        case .initiator:
            try await handshakeAsInitiator()
        case .responder:
            try await handshakeAsResponder()
        }
    }

    private func handshakeAsInitiator() async throws {
        guard let remoteKey = remoteWGPublicKey else {
            throw NoiseError.handshakeFailed("Initiator requires remote WG public key")
        }
        // Send message 1
        let (msg1, state) = try NoiseHandshake.initiatorBegin(
            localStatic: localIdentity.keyAgreementPrivateKey,
            remoteStaticPublic: remoteKey
        )
        var packet1 = Data([0x01])  // handshake initiation
        packet1.append(msg1)
        try await sendUDP(packet1)

        // Wait for message 2
        let response = try await receiveUDP(timeout: 10)
        guard response.first == 0x02 else {
            throw NoiseError.handshakeFailed("Expected handshake response (0x02), got \(response.first ?? 0)")
        }
        let msg2 = response.dropFirst()

        let keys = try NoiseHandshake.initiatorFinish(state: state, message2: Data(msg2))
        self.noiseSession = NoiseSession(keys: keys)
        connectionState = .connected
        isReady = true
    }

    private func handshakeAsResponder() async throws {
        // Wait for message 1
        let initiation = try await receiveUDP(timeout: 10)
        guard initiation.first == 0x01 else {
            throw NoiseError.handshakeFailed("Expected handshake initiation (0x01), got \(initiation.first ?? 0)")
        }
        let msg1 = initiation.dropFirst()

        let (msg2, keys, remoteStaticPub) = try NoiseHandshake.responderComplete(
            localStatic: localIdentity.keyAgreementPrivateKey,
            message1: Data(msg1)
        )

        // Send message 2
        var packet2 = Data([0x02])  // handshake response
        packet2.append(msg2)
        try await sendUDP(packet2)

        // Capture the revealed remote identity
        self.remoteWGPublicKeyRevealed = remoteStaticPub
        let revealedHex = remoteStaticPub.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        self.remoteNodeID = revealedHex  // Use WG public key hex as provisional nodeID

        self.noiseSession = NoiseSession(keys: keys)
        connectionState = .connected
        isReady = true
    }

    // MARK: - UDP I/O

    private func sendUDP(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConnection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
        lastSendTime = Date()
    }

    private func receiveUDP(timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    self.udpConnection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, _, error in
                        if let data = data {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: error ?? WANError.peerConnectionFailed("No data received"))
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                throw WANError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Receive Loop

    private nonisolated func receiveLoop() {
        Task { await _receiveLoop() }
    }

    private func _receiveLoop() {
        udpConnection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, _, error in
            guard let self = self else { return }

            guard let data = data, !data.isEmpty else {
                if error != nil {
                    Task { await self.handleReceiveError() }
                }
                return
            }

            Task {
                await self.handleReceivedPacket(data)
                await self._receiveLoop()
            }
        }
    }

    private func handleReceivedPacket(_ data: Data) {
        guard let session = noiseSession, let type = data.first else { return }

        let payload = data.dropFirst()

        switch type {
        case 0x04: // Transport data (single packet)
            guard let decrypted = try? session.decrypt(Data(payload)) else { return }
            decodeAndDeliver(decrypted)

        case 0x05: // Transport fragment
            guard let decrypted = try? session.decrypt(Data(payload)),
                  decrypted.count >= 8 else { return }
            handleFragment(decrypted)

        case 0x03: // Keepalive
            break

        default:
            break
        }
    }

    private func decodeAndDeliver(_ framed: Data) {
        // Parse length-prefixed JSON ClusterMessage
        guard framed.count >= 4 else { return }
        let length = framed.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard framed.count >= 4 + Int(length) else { return }
        let jsonData = framed[framed.index(framed.startIndex, offsetBy: 4)..<framed.index(framed.startIndex, offsetBy: 4 + Int(length))]
        guard let message = try? JSONDecoder().decode(ClusterMessage.self, from: jsonData) else { return }
        for continuation in subscribers.values { continuation.yield(message) }
    }

    private func handleFragment(_ data: Data) {
        let fragmentID = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let fragmentIndex = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let totalFragments = data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }
        let chunk = data[data.index(data.startIndex, offsetBy: 8)...]

        if fragments[fragmentID] == nil {
            fragments[fragmentID] = FragmentBuffer(total: Int(totalFragments))
        }

        fragments[fragmentID]?.insert(index: Int(fragmentIndex), data: Data(chunk))

        if let buffer = fragments[fragmentID], buffer.isComplete {
            fragments.removeValue(forKey: fragmentID)
            let reassembled = buffer.reassemble()
            decodeAndDeliver(reassembled)
        }

        // Prune stale fragments (older than 10 seconds would be handled by the fragment buffer)
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            break // Don't set isReady here — wait for handshake
        case .failed(let error):
            connectionState = .failed(error.localizedDescription)
            for continuation in subscribers.values { continuation.finish() }
            subscribers.removeAll()
        case .cancelled:
            connectionState = .disconnected
            for continuation in subscribers.values { continuation.finish() }
            subscribers.removeAll()
        case .waiting(let error):
            connectionState = .waiting(error.localizedDescription)
        default:
            break
        }
    }

    private func waitForReady() async {
        for _ in 0..<100 {
            if udpConnection.state == .ready { return }
            if case .failed = udpConnection.state {
                connectionState = .failed("UDP connection failed")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func handleReceiveError() {
        connectionState = .disconnected
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}

// MARK: - Connection State

public enum WANConnectionState: Sendable {
    case connecting
    case connected
    case waiting(String)
    case failed(String)
    case disconnected
}

// MARK: - Fragment Reassembly

private struct FragmentBuffer {
    let total: Int
    var received: [Int: Data] = [:]

    var isComplete: Bool { received.count == total }

    mutating func insert(index: Int, data: Data) {
        received[index] = data
    }

    func reassemble() -> Data {
        var result = Data()
        for i in 0..<total {
            if let chunk = received[i] {
                result.append(chunk)
            }
        }
        return result
    }
}

// MARK: - WireGuard Transport Factory

public enum WireGuardTransport {

    /// Connect to a WAN peer via Noise-encrypted UDP.
    public static func connect(
        to host: String,
        port: UInt16,
        remoteNodeID: String,
        remoteWGPublicKey: Curve25519.KeyAgreement.PublicKey,
        localIdentity: WANNodeIdentity
    ) -> WireGuardPeerConnection {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: nwHost, port: nwPort, using: .udp)

        return WireGuardPeerConnection(
            connection: connection,
            remoteNodeID: remoteNodeID,
            localIdentity: localIdentity,
            remoteWGPublicKey: remoteWGPublicKey,
            role: .initiator
        )
    }

    /// Create a UDP listener for incoming WireGuard connections.
    public static func createListener(
        port: UInt16,
        identity: WANNodeIdentity
    ) throws -> NWListener {
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        return listener
    }
}

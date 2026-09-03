import Foundation
import Network
import ClusterKit
import PINKit
import WANKit

/// Provider side of the PIN exit-node data plane (Phase 1): accepts
/// SOCKS5-over-Noise byte streams from fellow PIN members and egresses
/// them to the open internet. Device-sovereign: only streams naming a PIN
/// in LocalPinSettings.exitNodePins are served, and only from active,
/// non-disabled members of that exact PIN (signed-netmap check).
/// DNS resolves here, on the exit - consumers send hostnames, so
/// consumer-side DNS poisoning (the GFW case) never touches them.
public final class PINExitServer: @unchecked Sendable {

    /// Serialized writes to one egress TCP connection.
    private actor EgressStream {
        let conn: NWConnection
        var lastActivity = Date()
        init(conn: NWConnection) { self.conn = conn }
        func send(_ data: Data) async throws {
            lastActivity = Date()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
        func close() { conn.cancel() }
    }

    private actor StreamRegistry {
        private var streams: [UUID: EgressStream] = [:]
        func add(_ id: UUID, _ stream: EgressStream) { streams[id] = stream }
        func stream(for id: UUID) -> EgressStream? { streams[id] }
        func remove(_ id: UUID) async {
            if let s = streams.removeValue(forKey: id) { await s.close() }
        }
        /// Reap streams idle longer than the interval (leak backstop; the
        /// normal teardown is socksClose / destination close).
        func reapIdle(olderThan interval: TimeInterval) async {
            let now = Date()
            for (id, s) in streams {
                let idle = await now.timeIntervalSince(s.lastActivity)
                if idle > interval {
                    streams.removeValue(forKey: id)
                    await s.close()
                    PINExitServer.log("reaped idle stream \(id)")
                }
            }
        }
    }

    private let pinService: PINService
    private let registry = StreamRegistry()
    private var reaperTask: Task<Void, Never>?

    public init(pinService: PINService) {
        self.pinService = pinService
        reaperTask = Task { [registry] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await registry.reapIdle(olderThan: 30 * 60)
            }
        }
    }

    deinit { reaperTask?.cancel() }

    /// Entry point: WANManager's socks dispatch lands here.
    public func handle(
        _ message: ClusterMessage, on transport: WANTransportConnection, from peerNodeID: String
    ) async {
        switch message {
        case .socksOpen(let payload):
            await handleOpen(payload, on: transport, from: peerNodeID)
        case .socksData(let payload):
            if let stream = await registry.stream(for: payload.streamID) {
                do { try await stream.send(payload.data) } catch {
                    await registry.remove(payload.streamID)
                    try? await transport.send(.socksClose(SocksClosePayload(
                        streamID: payload.streamID, reason: "egress write failed")))
                }
            } else {
                try? await transport.send(.socksClose(SocksClosePayload(
                    streamID: payload.streamID, reason: "unknown stream")))
            }
        case .socksClose(let payload):
            await registry.remove(payload.streamID)
        default:
            break
        }
    }

    private func handleOpen(
        _ payload: SocksOpenPayload, on transport: WANTransportConnection, from peerNodeID: String
    ) async {
        func refuse(_ reason: String) async {
            Self.log("refused stream \(payload.streamID) from \(peerNodeID.prefix(12)): \(reason)")
            try? await transport.send(.socksOpenResult(SocksOpenResultPayload(
                streamID: payload.streamID, ok: false, error: reason)))
        }

        // Device-sovereign consent: only PINs this device opted into.
        let settings = await pinService.manager.settings()
        guard settings.exitNodePins.contains(payload.pinId) else {
            await refuse("this device does not offer exit for that network")
            return
        }
        // Authorization: active, non-disabled member of THAT pin.
        guard await pinService.manager.member(pinId: payload.pinId, nodePubkey: peerNodeID) != nil else {
            await refuse("not an active member of that network")
            return
        }
        guard let port = NWEndpoint.Port(rawValue: payload.destPort) else {
            await refuse("invalid destination port")
            return
        }

        // DNS resolves here on the exit for hostname destinations.
        let conn = NWConnection(
            host: NWEndpoint.Host(payload.destHost), port: port, using: .tcp)
        do {
            try await Self.waitReady(conn, timeout: 15)
        } catch {
            conn.cancel()
            await refuse("destination unreachable: \(error.localizedDescription)")
            return
        }

        let stream = EgressStream(conn: conn)
        await registry.add(payload.streamID, stream)
        Self.log("opened stream \(payload.streamID) -> \(payload.destHost):\(payload.destPort) for \(peerNodeID.prefix(12)) pin=\(payload.pinId.prefix(8))")
        try? await transport.send(.socksOpenResult(SocksOpenResultPayload(
            streamID: payload.streamID, ok: true)))

        // Egress -> consumer shuttle; teardown on destination close.
        let registry = self.registry
        Task {
            while true {
                guard let data = await Self.recv(conn, max: 8192) else { break }
                do {
                    try await transport.send(.socksData(SocksDataPayload(
                        streamID: payload.streamID, data: data)))
                } catch { break }
            }
            await registry.remove(payload.streamID)
            try? await transport.send(.socksClose(SocksClosePayload(
                streamID: payload.streamID, reason: "destination closed")))
        }
    }

    private static func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            func once(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                conn.stateUpdateHandler = nil
                cont.resume(with: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once(.success(()))
                case .failed(let e): once(.failure(e))
                case .waiting(let e): once(.failure(e))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once(.failure(NWError.posix(.ETIMEDOUT)))
            }
        }
    }

    /// Receive up to `max` bytes; nil when the connection closed.
    private static func recv(_ conn: NWConnection, max: Int) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimum: 1, maximum: max) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[PINExit] \(message)\n".utf8))
    }
}

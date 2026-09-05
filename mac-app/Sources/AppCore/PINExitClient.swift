import Foundation
import Network
import CryptoKit
import ClusterKit
import PINKit
import WANKit

/// Consumer side of the PIN exit-node data plane (Phase 1): routes local
/// traffic through a fellow PIN member that offers exit. Runs a standard
/// SOCKS5 listener on 127.0.0.1 - point macOS System Settings -> Network
/// -> Proxies (or a browser) at it. Hostnames travel to the exit node and
/// resolve THERE (SOCKS5 ATYP=3), so local DNS poisoning - the GFW case -
/// is bypassed. No root, no Network Extension.
public final class PINExitClient: @unchecked Sendable {

    public struct Status: Codable, Sendable, Equatable {
        /// "off" | "connecting" | "listening" | "failed"
        public var state: String
        public var pinId: String?
        public var viaDevice: String?
        public var host: String?
        public var port: Int?
        public var error: String?

        public static let off = Status(state: "off", pinId: nil, viaDevice: nil, host: nil, port: nil, error: nil)
    }

    public enum ExitError: Error, CustomStringConvertible {
        case noExitProviders(String)
        case dialFailed(String)
        case openFailed(String)
        /// The exit node answered the open with a refusal - distinct from a
        /// timeout because an answer proves the transport path is alive.
        case openRefused(String)
        public var description: String {
            switch self {
            case .noExitProviders(let m): return m
            case .dialFailed(let m): return m
            case .openFailed(let m): return m
            case .openRefused(let m): return m
            }
        }
    }

    /// Serialized writes to one local SOCKS client connection.
    private actor LocalStream {
        let conn: NWConnection
        init(conn: NWConnection) { self.conn = conn }
        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
        func close() { conn.cancel() }
    }

    private actor StateBox {
        var status: Status = .off
        func set(_ s: Status) { status = s }
        func get() -> Status { status }
    }

    private let pinService: PINService
    private let selfDeviceId: String
    private let stateBox = StateBox()
    private var listener: NWListener?
    private var transport: WANTransportConnection?
    /// True when we dialed the transport ourselves (cancel on stop); false
    /// when it belongs to WANManager's peer table.
    private var ownsTransport = false
    /// Guards transport/ownsTransport/route: start/stop run under
    /// lifecycleLock, but SOCKS client handlers read and redial concurrently.
    private let transportLock = NSLock()
    /// Active route + dialer, kept so a dead transport can be redialed
    /// without a full stop/start cycle.
    private var route: (pinId: String, member: PinNetmapMember)?
    private var wanManagerRef: WANManager?
    private var activeStreams: [UUID: LocalStream] = [:]
    private let streamsLock = NSLock()
    /// Serialized start/stop.
    private let lifecycleLock = NSLock()
    /// Watches the provider's exit offer for the lifetime of the listener
    /// (Bug D: offer withdrawn mid-route used to leave us "listening").
    private var offerWatcher: Task<Void, Never>?

    public init(pinService: PINService, selfDeviceId: String) {
        self.pinService = pinService
        self.selfDeviceId = selfDeviceId
    }

    public func status() async -> Status { await stateBox.get() }

    // MARK: - Lifecycle

    /// Start routing `pinId`'s traffic through an exit provider. Picks
    /// `deviceId` when given, else any active exit member. listenPort 0 =
    /// ephemeral (reported in status).
    public func start(
        pinId: String, deviceId: String?, listenPort: UInt16, wanManager: WANManager
    ) async throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        await stopLocked()

        // The consumer-side netmap cache can lag the provider's offer by a
        // sync round (phantom "no exit providers" on the first attempt) -
        // poll a few times before declaring the network empty.
        var member: PinNetmapMember?
        for attempt in 1...4 {
            let candidates = await pinService.manager.exitMembers(
                pinId: pinId, excludingDeviceId: selfDeviceId)
            if let deviceId {
                member = candidates.first { $0.deviceId == deviceId }
            } else {
                member = candidates.first
            }
            if member != nil { break }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        guard let member else {
            await stateBox.set(Status(
                state: "failed", pinId: pinId, viaDevice: nil, host: nil, port: nil,
                error: "no exit providers in this network (is one online with the exit toggle on?)"))
            throw ExitError.noExitProviders("no exit providers in network \(pinId)")
        }
        let viaName = member.displayName ?? member.deviceId
        await stateBox.set(Status(
            state: "connecting", pinId: pinId, viaDevice: viaName, host: nil, port: nil, error: nil))
        PINExitServer.log("exit client: dialing \(viaName) for pin \(pinId.prefix(8))...")

        do {
            let (conn, owned) = try await dial(member: member, pinId: pinId, wanManager: wanManager)
            transportLock.lock()
            transport = conn
            ownsTransport = owned
            route = (pinId: pinId, member: member)
            wanManagerRef = wanManager
            transportLock.unlock()
        } catch {
            await stateBox.set(Status(
                state: "failed", pinId: pinId, viaDevice: viaName, host: nil, port: nil,
                error: "could not reach exit node: \(error.localizedDescription)"))
            throw error
        }

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let port: NWEndpoint.Port = listenPort == 0 ? .any : NWEndpoint.Port(rawValue: listenPort)!
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: port)
        } catch {
            await stateBox.set(Status(
                state: "failed", pinId: pinId, viaDevice: viaName, host: nil, port: nil,
                error: "could not bind local proxy: \(error.localizedDescription)"))
            transportLock.lock()
            let boundTransport = transport
            let boundOwned = ownsTransport
            transport = nil
            ownsTransport = false
            transportLock.unlock()
            if boundOwned { await boundTransport?.cancel() }
            throw error
        }
        let pinIdCopy = pinId
        newListener.newConnectionHandler = { [weak self] inbound in
            guard let self else { inbound.cancel(); return }
            Task { await self.handleSocksClient(inbound, pinId: pinIdCopy) }
        }
        listener = newListener
        let stateBox = self.stateBox
        newListener.stateUpdateHandler = { [weak newListener] state in
            if case .ready = state, let bound = newListener?.port {
                Task {
                    await stateBox.set(Status(
                        state: "listening", pinId: pinIdCopy, viaDevice: viaName,
                        host: "127.0.0.1", port: Int(bound.rawValue), error: nil))
                }
                PINExitServer.log("exit client: SOCKS5 listening on 127.0.0.1:\(bound.rawValue) via \(viaName)")
            }
        }
        newListener.start(queue: .global(qos: .userInitiated))
        await stateBox.set(Status(
            state: "listening", pinId: pinId, viaDevice: viaName,
            host: "127.0.0.1", port: Int(listenPort), error: nil))
        startOfferWatcher(pinId: pinId)
    }

    public func stop() async {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        await stopLocked()
    }

    private func stopLocked() async {
        offerWatcher?.cancel()
        offerWatcher = nil
        listener?.cancel()
        listener = nil
        streamsLock.lock()
        let streams = activeStreams
        activeStreams.removeAll()
        streamsLock.unlock()
        for (_, s) in streams { await s.close() }
        transportLock.lock()
        let oldTransport = transport
        let oldOwned = ownsTransport
        transport = nil
        ownsTransport = false
        route = nil
        wanManagerRef = nil
        transportLock.unlock()
        if oldOwned { await oldTransport?.cancel() }
        await stateBox.set(.off)
    }

    // MARK: - Dialing

    /// Reach the exit member. The WANManager path does its own
    /// offer/answer + relay fallback (PRIMARY on China lanes - direct UDP
    /// is usually unavailable); the manual ladder covers relay-independent
    /// LAN/offline PINs.
    private func dial(
        member: PinNetmapMember, pinId: String, wanManager: WANManager
    ) async throws -> (WANTransportConnection, Bool) {
        if let existing = await wanManager.connectedPeers(byNodeID: member.nodePubkey) {
            // A peer-table entry (or even a completed handshake) is not
            // proof the data path works: duplicate tailscaled identities
            // can answer the handshake on a stale IP while return packets
            // leave via the other instance (Bug C). Verify with a probe.
            if await existing.isLive, await verifyTransport(existing, pinId: pinId) {
                PINExitServer.log("exit client: reusing WAN connection to \(member.nodePubkey.prefix(12))")
                return (existing, false)
            }
            // Stale or asymmetric peer-table entry: reusing it sends
            // socksOpen into the void - evict and fall through to a fresh
            // dial.
            PINExitServer.log("exit client: cached WAN connection to \(member.nodePubkey.prefix(12)) is dead, redialing")
            await wanManager.disconnectPeer(member.nodePubkey)
        }
        // WANManager connect (discovery-based: direct attempt, relay fallback).
        let connectTask = Task { try? await wanManager.connectToPeer(nodeID: member.nodePubkey) }
        wanPoll: for _ in 0..<90 {
            if let connected = await wanManager.connectedPeers(byNodeID: member.nodePubkey) {
                connectTask.cancel()
                if await verifyTransport(connected, pinId: pinId) {
                    PINExitServer.log("exit client: WANManager connected to \(member.nodePubkey.prefix(12))")
                    return (connected, false)
                }
                PINExitServer.log("exit client: WANManager path failed probe, falling back to manual ladder")
                await wanManager.disconnectPeer(member.nodePubkey)
                break wanPoll
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        connectTask.cancel()

        // Manual ladder: lan, then reflexive (relay endpoints need the
        // discovery path above, which already failed). ALL endpoints are
        // raced concurrently and only a VERIFIED connection wins: a stale
        // duplicate tailscaled identity can answer the Noise handshake yet
        // blackhole the return path, so "handshake done" must not win.
        guard let wgKeyData = Data(hexString: member.wgPubkey),
            let wgKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: wgKeyData)
        else { throw ExitError.dialFailed("exit node has no usable key") }
        let identity = try AppState.canonicalWANIdentity()
        var seen = Set<String>()
        let ordered = (member.endpoints.filter { $0.kind == "lan" }
            + member.endpoints.filter { $0.kind == "reflexive" })
            .filter { seen.insert($0.addr).inserted }
        let winner: WireGuardPeerConnection? = await withTaskGroup(
            of: WireGuardPeerConnection?.self
        ) { group in
            for endpoint in ordered {
                let parts = endpoint.addr.split(separator: ":")
                guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
                let host = String(parts[0])
                group.addTask {
                    let dialed = WireGuardTransport.connect(
                        to: host, port: port,
                        remoteNodeID: member.nodePubkey,
                        remoteWGPublicKey: wgKey,
                        localIdentity: identity)
                    PINExitServer.log("exit client: dialing \(endpoint.addr)")
                    let startTask = Task { await dialed.start() }
                    poll: for _ in 0..<48 {  // 12s handshake budget
                        if Task.isCancelled { break poll }
                        switch await dialed.connectionState {
                        case .connected:
                            startTask.cancel()
                            if await self.verifyTransport(dialed, pinId: pinId) {
                                return dialed
                            }
                            break poll
                        case .failed, .disconnected:
                            break poll
                        default:
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                    await dialed.cancel()
                    startTask.cancel()
                    return nil
                }
            }
            var first: WireGuardPeerConnection?
            for await candidate in group {
                if let candidate {
                    if first == nil {
                        first = candidate
                        group.cancelAll()
                    } else {
                        await candidate.cancel()
                    }
                }
            }
            return first
        }
        if let winner { return (.direct(winner), true) }
        throw ExitError.dialFailed("all routes to exit node failed")
    }

    /// Prove the bidirectional data path before a connection is declared
    /// usable. A completed Noise handshake is NOT enough (Bug C: with
    /// duplicate tailscaled identities the handshake lands on a stale
    /// instance whose return path is blackholed). We send a probe socksOpen
    /// to 127.0.0.1:9 (always instantly refused) and require ANY
    /// socksOpenResult back - a refusal proves the path, silence proves it
    /// dead.
    private func verifyTransport(_ conn: WANTransportConnection, pinId: String) async -> Bool {
        let probeID = UUID()
        do {
            try await conn.send(.socksOpen(SocksOpenPayload(
                pinId: pinId, streamID: probeID, destHost: "127.0.0.1", destPort: 9)))
            try await awaitOpenResult(streamID: probeID, on: conn, timeoutSeconds: 6)
            // The probe target actually accepted a connection - odd, but
            // the path is proven either way.
            return true
        } catch ExitError.openRefused(let reason) {
            PINExitServer.log("exit client: transport verified (probe refused as expected: \(reason))")
            return true
        } catch {
            PINExitServer.log("exit client: transport probe unanswered: \(error.localizedDescription)")
            return false
        }
    }

    /// Bug D: watch the offer for the lifetime of the listener. If the
    /// provider goes offline or withdraws its exit offer, tear the route
    /// down instead of sitting "listening" with traffic dying silently.
    private func startOfferWatcher(pinId: String) {
        offerWatcher?.cancel()
        offerWatcher = Task { [weak self] in
            var emptyPolls = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                let members = await self.pinService.manager.exitMembers(
                    pinId: pinId, excludingDeviceId: self.selfDeviceId)
                // Two consecutive empty polls (~20s) guard against netmap
                // sync gaps tearing down a healthy route.
                emptyPolls = members.isEmpty ? emptyPolls + 1 : 0
                if emptyPolls >= 2 {
                    PINExitServer.log("exit client: exit offer withdrawn for pin \(pinId.prefix(8)) - tearing down listener")
                    await self.tearDownWithdrawnRoute(pinId: pinId)
                    break
                }
            }
        }
    }

    private func tearDownWithdrawnRoute(pinId: String) async {
        listener?.cancel()
        listener = nil
        streamsLock.lock()
        let streams = activeStreams
        activeStreams.removeAll()
        streamsLock.unlock()
        for (_, s) in streams { await s.close() }
        transportLock.lock()
        let old = transport
        let owned = ownsTransport
        let wanManager = wanManagerRef
        let oldRoute = route
        transport = nil
        ownsTransport = false
        route = nil
        wanManagerRef = nil
        transportLock.unlock()
        if owned {
            await old?.cancel()
        } else if old != nil, let wanManager, let oldRoute {
            await wanManager.disconnectPeer(oldRoute.member.nodePubkey)
        }
        await stateBox.set(Status(
            state: "failed", pinId: pinId, viaDevice: nil, host: nil, port: nil,
            error: "exit provider went offline or withdrew its offer"))
    }

    // MARK: - SOCKS5

    private func handleSocksClient(_ inbound: NWConnection, pinId: String) async {
        inbound.start(queue: .global(qos: .userInitiated))
        do {
            // Greeting: VER NMETHODS METHODS...
            guard let greeting = try await Self.readExactly(inbound, 2),
                greeting[0] == 0x05
            else { inbound.cancel(); return }
            _ = try await Self.readExactly(inbound, Int(greeting[1]))
            try await Self.sendRaw(inbound, Data([0x05, 0x00]))  // no auth

            // Request: VER CMD RSV ATYP ...
            guard let header = try await Self.readExactly(inbound, 4),
                header[0] == 0x05
            else { inbound.cancel(); return }
            guard header[1] == 0x01 else {  // CONNECT only
                try await Self.sendRaw(inbound, Self.socksReply(0x07))
                inbound.cancel()
                return
            }
            let host: String
            switch header[3] {
            case 0x01:  // IPv4
                guard let b = try await Self.readExactly(inbound, 4) else { inbound.cancel(); return }
                host = b.map { String($0) }.joined(separator: ".")
            case 0x03:  // domain - resolved on the EXIT side
                guard let lenB = try await Self.readExactly(inbound, 1),
                    let b = try await Self.readExactly(inbound, Int(lenB[0])),
                    let name = String(data: b, encoding: .utf8)
                else { inbound.cancel(); return }
                host = name
            case 0x04:  // IPv6
                guard let b = try await Self.readExactly(inbound, 16) else { inbound.cancel(); return }
                var parts: [String] = []
                for i in stride(from: 0, to: 16, by: 2) {
                    parts.append(String(format: "%x", UInt16(b[i]) << 8 | UInt16(b[i + 1])))
                }
                host = parts.joined(separator: ":")
            default:
                try await Self.sendRaw(inbound, Self.socksReply(0x08))
                inbound.cancel()
                return
            }
            guard let portB = try await Self.readExactly(inbound, 2) else { inbound.cancel(); return }
            let destPort = UInt16(portB[0]) << 8 | UInt16(portB[1])

            // Open the stream on the exit node, redialing once if the
            // cached transport died under us.
            let streamID = UUID()
            let transport: WANTransportConnection
            do {
                transport = try await openStream(
                    streamID: streamID, pinId: pinId, host: host, port: destPort)
                var s = await stateBox.get()
                if s.error != nil {
                    s.error = nil
                    await stateBox.set(s)
                }
            } catch {
                var s = await stateBox.get()
                s.error = "last open failed: \(error.localizedDescription)"
                await stateBox.set(s)
                try? await Self.sendRaw(inbound, Self.socksReply(0x01))
                inbound.cancel()
                return
            }
            try await Self.sendRaw(inbound, Self.socksReply(0x00))

            let local = LocalStream(conn: inbound)
            streamsLock.lock()
            activeStreams[streamID] = local
            streamsLock.unlock()
            PINExitServer.log("exit client: \(host):\(destPort) via stream \(streamID)")

            // Local -> exit shuttle; the exit -> local half lives in the
            // message pump started below.
            Task { [weak self] in
                guard let self else { return }
                while true {
                    guard let data = await Self.recv(inbound, max: 8192) else { break }
                    do {
                        try await transport.send(.socksData(SocksDataPayload(
                            streamID: streamID, data: data)))
                    } catch {
                        PINExitServer.log("exit client: local->exit send FAILED for \(streamID): \(error.localizedDescription)")
                        break
                    }
                }
                try? await transport.send(.socksClose(SocksClosePayload(
                    streamID: streamID, reason: "client closed")))
                await self.dropStream(streamID)
            }
            startMessagePump(for: streamID, local: local, on: transport)
        } catch {
            inbound.cancel()
        }
    }

    private func currentTransport() -> WANTransportConnection? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return transport
    }

    /// Send socksOpen and await the result, redialing the exit once when the
    /// cached transport is dead (relay sessions drop silently - the peer
    /// table entry outlives the session, and a "listening" status alone said
    /// nothing about it).
    private func openStream(
        streamID: UUID, pinId: String, host: String, port: UInt16
    ) async throws -> WANTransportConnection {
        var lastError: Error = ExitError.openFailed("no route to exit node")
        for attempt in 1...2 {
            guard let transport = currentTransport() else {
                if attempt < 2 { await redial(); continue }
                throw lastError
            }
            do {
                try await transport.send(.socksOpen(SocksOpenPayload(
                    pinId: pinId, streamID: streamID, destHost: host, destPort: port)))
                try await awaitOpenResult(streamID: streamID, on: transport)
                return transport
            } catch {
                lastError = error
                PINExitServer.log("exit client: open attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 2 { await redial() }
            }
        }
        throw lastError
    }

    /// Drop the cached transport (evicting WANManager's stale peer-table
    /// entry when we don't own it) and dial the route's exit member again.
    /// Re-reads the netmap so a provider that changed endpoints is found.
    private func redial() async {
        transportLock.lock()
        let route = self.route
        let wanManager = self.wanManagerRef
        let old = transport
        let owned = ownsTransport
        transport = nil
        ownsTransport = false
        transportLock.unlock()
        guard let route, let wanManager else { return }
        if owned { await old?.cancel() } else if old != nil {
            await wanManager.disconnectPeer(route.member.nodePubkey)
        }
        let members = await pinService.manager.exitMembers(
            pinId: route.pinId, excludingDeviceId: selfDeviceId)
        let member = members.first { $0.deviceId == route.member.deviceId }
            ?? members.first { $0.nodePubkey == route.member.nodePubkey }
            ?? route.member
        do {
            let (conn, newOwned) = try await dial(member: member, pinId: route.pinId, wanManager: wanManager)
            transportLock.lock()
            transport = conn
            ownsTransport = newOwned
            self.route = (pinId: route.pinId, member: member)
            transportLock.unlock()
            PINExitServer.log("exit client: redialed \(member.nodePubkey.prefix(12))")
        } catch {
            PINExitServer.log("exit client: redial failed: \(error.localizedDescription)")
        }
    }

    /// Pump exit -> local messages for one stream until close.
    private func startMessagePump(
        for streamID: UUID, local: LocalStream, on transport: WANTransportConnection
    ) {
        Task { [weak self] in
            guard let self else { return }
            var totalBytes = 0
            let messages = await transport.incomingMessages
            for await message in messages {
                switch message {
                case .socksData(let payload) where payload.streamID == streamID:
                    totalBytes += payload.data.count
                    do { try await local.send(payload.data) } catch {
                        PINExitServer.log("exit client: local send FAILED for \(streamID) after \(totalBytes) bytes: \(error.localizedDescription)")
                        await self.dropStream(streamID)
                        return
                    }
                case .socksClose(let payload) where payload.streamID == streamID:
                    PINExitServer.log("exit client: stream \(streamID) closed by exit (\(payload.reason ?? "no reason")) after \(totalBytes) bytes exit->local")
                    await self.dropStream(streamID)
                    return
                default:
                    break
                }
            }
            PINExitServer.log("exit client: transport ended under stream \(streamID) after \(totalBytes) bytes exit->local")
            await self.dropStream(streamID)
        }
    }

    private func dropStream(_ streamID: UUID) async {
        streamsLock.lock()
        let s = activeStreams.removeValue(forKey: streamID)
        streamsLock.unlock()
        if let s { await s.close() }
    }

    private func awaitOpenResult(
        streamID: UUID, on transport: WANTransportConnection, timeoutSeconds: UInt64 = 15
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw ExitError.openFailed("exit node did not answer")
            }
            group.addTask {
                let messages = await transport.incomingMessages
                for await message in messages {
                    if case .socksOpenResult(let result) = message, result.streamID == streamID {
                        if result.ok { return }
                        throw ExitError.openRefused(result.error ?? "refused")
                    }
                }
                throw ExitError.openFailed("exit node disconnected")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Byte helpers

    private static func readExactly(_ conn: NWConnection, _ count: Int) async throws -> Data? {
        guard count > 0 else { return Data() }
        var out = Data()
        while out.count < count {
            guard let chunk = await recv(conn, max: count - out.count) else { return nil }
            out.append(chunk)
        }
        return out
    }

    private static func recv(_ conn: NWConnection, max: Int) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, _, _ in
                if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func sendRaw(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// SOCKS5 reply with a zero bound address (RFC 1928 permits).
    private static func socksReply(_ code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }
}

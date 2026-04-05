import Foundation
import Network

// MARK: - NAT Type

public enum NATType: String, Codable, Sendable {
    case fullCone           // Any external host can send to mapped port
    case restrictedCone     // Only hosts we've sent to can reply (any port)
    case portRestricted     // Only hosts we've sent to can reply (same port)
    case symmetric          // Different mapping per destination — hardest to traverse
    case unknown

    /// Whether direct P2P connection is likely possible
    public var canHolePunch: Bool {
        switch self {
        case .fullCone, .restrictedCone, .portRestricted: return true
        case .symmetric, .unknown: return false
        }
    }
}

// MARK: - NAT Mapping

public struct NATMapping: Sendable {
    public var publicIP: String
    public var publicPort: UInt16
    public var natType: NATType

    public init(publicIP: String, publicPort: UInt16, natType: NATType = .unknown) {
        self.publicIP = publicIP
        self.publicPort = publicPort
        self.natType = natType
    }
}

// MARK: - STUN Client

public actor STUNClient {
    // STUN magic cookie (RFC 5389)
    private static let magicCookie: UInt32 = 0x2112A442

    // STUN message types
    private static let bindingRequest: UInt16 = 0x0001
    private static let bindingResponse: UInt16 = 0x0101

    // STUN attribute types
    private static let attrMappedAddress: UInt16 = 0x0001
    private static let attrXorMappedAddress: UInt16 = 0x0020

    private let stunServers: [URL]
    private let timeoutSeconds: TimeInterval

    public init(stunServers: [URL] = [], timeoutSeconds: TimeInterval = 5) {
        self.stunServers = stunServers.isEmpty ? [
            URL(string: "stun://stun.l.google.com:19302")!,
            URL(string: "stun://stun1.l.google.com:19302")!,
        ] : stunServers
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Public API

    /// Discover our public IP:port by querying STUN servers
    public func discoverMapping() async throws -> NATMapping {
        // Query first available STUN server
        for server in stunServers {
            do {
                let mapping = try await querySTUN(server: server)
                return mapping
            } catch {
                continue
            }
        }
        throw WANError.stunFailed("All STUN servers unreachable")
    }

    /// Determine NAT type by querying multiple STUN servers
    public func detectNATType() async throws -> NATType {
        guard stunServers.count >= 2 else {
            let mapping = try await discoverMapping()
            return mapping.natType
        }

        // Query two different STUN servers from the same local port
        let localPort = UInt16.random(in: 49152...65535)

        do {
            let mapping1 = try await querySTUN(server: stunServers[0], localPort: localPort)
            let mapping2 = try await querySTUN(server: stunServers[1], localPort: localPort)

            if mapping1.publicIP == mapping2.publicIP && mapping1.publicPort == mapping2.publicPort {
                // Same mapped address for different destinations — not symmetric
                // Could be full cone, restricted, or port-restricted
                // Without additional tests, assume port-restricted (most common)
                return .portRestricted
            } else if mapping1.publicIP == mapping2.publicIP {
                // Same IP but different port — symmetric NAT
                return .symmetric
            } else {
                // Different IP — multi-homed or very unusual NAT
                return .symmetric
            }
        } catch {
            return .unknown
        }
    }

    // MARK: - STUN Protocol

    /// Query a single STUN server
    private func querySTUN(server: URL, localPort: UInt16? = nil) async throws -> NATMapping {
        let host = server.host ?? "stun.l.google.com"
        let port = UInt16(server.port ?? 3478)

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        let params = NWParameters.udp
        if let localPort = localPort {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.any),
                port: NWEndpoint.Port(rawValue: localPort)!
            )
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: params)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NATMapping, Error>) in
            var completed = false

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Build and send STUN binding request
                    let request = Self.buildBindingRequest()
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error = error {
                            guard !completed else { return }
                            completed = true
                            connection.cancel()
                            continuation.resume(throwing: WANError.stunFailed(error.localizedDescription))
                        }
                    })

                    // Receive response
                    connection.receive(minimumIncompleteLength: 20, maximumLength: 548) { data, _, _, error in
                        guard !completed else { return }
                        completed = true
                        connection.cancel()

                        if let error = error {
                            continuation.resume(throwing: WANError.stunFailed(error.localizedDescription))
                            return
                        }

                        guard let data = data else {
                            continuation.resume(throwing: WANError.stunFailed("No response data"))
                            return
                        }

                        do {
                            let mapping = try Self.parseBindingResponse(data)
                            continuation.resume(returning: mapping)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                case .failed(let error):
                    guard !completed else { return }
                    completed = true
                    continuation.resume(throwing: WANError.stunFailed(error.localizedDescription))

                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeoutSeconds) {
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(throwing: WANError.timeout)
            }
        }
    }

    // MARK: - STUN Message Building

    /// Build a STUN Binding Request (RFC 5389)
    public static func buildBindingRequest() -> Data {
        var data = Data(capacity: 20)

        // Message type: Binding Request (0x0001)
        var msgType = bindingRequest.bigEndian
        data.append(Data(bytes: &msgType, count: 2))

        // Message length: 0 (no attributes)
        var msgLen: UInt16 = 0
        data.append(Data(bytes: &msgLen, count: 2))

        // Magic cookie
        var cookie = magicCookie.bigEndian
        data.append(Data(bytes: &cookie, count: 4))

        // Transaction ID (12 random bytes)
        var transactionID = Data(count: 12)
        _ = transactionID.withUnsafeMutableBytes { buffer in
            if let ptr = buffer.baseAddress {
                arc4random_buf(ptr, 12)
            }
        }
        data.append(transactionID)

        return data
    }

    // MARK: - STUN Response Parsing

    /// Parse a STUN Binding Response and extract the mapped address
    public static func parseBindingResponse(_ data: Data) throws -> NATMapping {
        guard data.count >= 20 else {
            throw WANError.stunFailed("Response too short")
        }

        let msgType = data.readUInt16(at: 0)
        guard msgType == bindingResponse else {
            throw WANError.stunFailed("Not a binding response (type: \(msgType))")
        }

        let msgLength = Int(data.readUInt16(at: 2))
        guard data.count >= 20 + msgLength else {
            throw WANError.stunFailed("Response truncated")
        }

        // Parse attributes
        var offset = 20
        while offset + 4 <= 20 + msgLength {
            let attrType = data.readUInt16(at: offset)
            let attrLength = Int(data.readUInt16(at: offset + 2))

            guard offset + 4 + attrLength <= data.count else { break }

            let attrData = data.subdata(in: (offset + 4)..<(offset + 4 + attrLength))

            if attrType == attrXorMappedAddress {
                let mapping = try parseXorMappedAddress(attrData, transactionID: data.subdata(in: 8..<20))
                return mapping
            } else if attrType == attrMappedAddress {
                let mapping = try parseMappedAddress(attrData)
                return mapping
            }

            // Attributes are padded to 4-byte boundaries
            let paddedLength = (attrLength + 3) & ~3
            offset += 4 + paddedLength
        }

        throw WANError.stunFailed("No mapped address in response")
    }

    /// Parse XOR-MAPPED-ADDRESS attribute
    private static func parseXorMappedAddress(_ data: Data, transactionID: Data) throws -> NATMapping {
        guard data.count >= 8 else {
            throw WANError.stunFailed("XOR-MAPPED-ADDRESS too short")
        }

        let family = data[1]
        let xorPort = data.readUInt16(at: 2)
        let port = xorPort ^ UInt16(magicCookie >> 16)

        if family == 0x01 {
            // IPv4
            let xorAddr = data.readUInt32(at: 4)
            let addr = xorAddr ^ magicCookie
            let ip = "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
            return NATMapping(publicIP: ip, publicPort: port)
        }

        throw WANError.stunFailed("Unsupported address family: \(family)")
    }

    /// Parse MAPPED-ADDRESS attribute
    private static func parseMappedAddress(_ data: Data) throws -> NATMapping {
        guard data.count >= 8 else {
            throw WANError.stunFailed("MAPPED-ADDRESS too short")
        }

        let family = data[1]
        let port = data.readUInt16(at: 2)

        if family == 0x01 {
            // IPv4
            let ip = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
            return NATMapping(publicIP: ip, publicPort: port)
        }

        throw WANError.stunFailed("Unsupported address family: \(family)")
    }
}

// MARK: - Data reading helpers

extension Data {
    public func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return self.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
    }

    public func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
    }
}

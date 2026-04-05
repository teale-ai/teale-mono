import XCTest
import CryptoKit
@testable import WANKit

final class WANNodeIdentityTests: XCTestCase {

    func testKeyGeneration() {
        let identity = WANNodeIdentity()

        // Node ID should be 64 hex characters (32 bytes = Ed25519 public key)
        XCTAssertEqual(identity.nodeID.count, 64)

        // Node ID should be valid hex
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(identity.nodeID.unicodeScalars.allSatisfy { hexChars.contains($0) })
    }

    func testUniqueKeys() {
        let identity1 = WANNodeIdentity()
        let identity2 = WANNodeIdentity()

        XCTAssertNotEqual(identity1.nodeID, identity2.nodeID)
    }

    func testSignAndVerify() throws {
        let identity = WANNodeIdentity()
        let message = Data("Hello, WAN!".utf8)

        let signature = try identity.sign(message)
        XCTAssertFalse(signature.isEmpty)

        // Verify with the public key
        let isValid = WANNodeIdentity.verify(
            signature: signature,
            data: message,
            publicKey: identity.publicKey
        )
        XCTAssertTrue(isValid)
    }

    func testVerifyWithHexPublicKey() throws {
        let identity = WANNodeIdentity()
        let message = Data("test message".utf8)

        let signature = try identity.sign(message)

        let isValid = WANNodeIdentity.verify(
            signature: signature,
            data: message,
            publicKeyHex: identity.nodeID
        )
        XCTAssertTrue(isValid)
    }

    func testVerifyWrongMessage() throws {
        let identity = WANNodeIdentity()
        let message = Data("correct message".utf8)
        let wrongMessage = Data("wrong message".utf8)

        let signature = try identity.sign(message)

        let isValid = WANNodeIdentity.verify(
            signature: signature,
            data: wrongMessage,
            publicKey: identity.publicKey
        )
        XCTAssertFalse(isValid)
    }

    func testVerifyWrongKey() throws {
        let identity1 = WANNodeIdentity()
        let identity2 = WANNodeIdentity()
        let message = Data("test".utf8)

        let signature = try identity1.sign(message)

        let isValid = WANNodeIdentity.verify(
            signature: signature,
            data: message,
            publicKey: identity2.publicKey
        )
        XCTAssertFalse(isValid)
    }

    func testRestoreFromPrivateKey() throws {
        let original = WANNodeIdentity()
        let privateKeyData = original.privateKey.rawRepresentation

        let restored = try WANNodeIdentity(privateKeyData: privateKeyData)

        XCTAssertEqual(original.nodeID, restored.nodeID)

        // Verify cross-signing works
        let message = Data("cross-sign test".utf8)
        let signature = try original.sign(message)
        let isValid = WANNodeIdentity.verify(
            signature: signature,
            data: message,
            publicKey: restored.publicKey
        )
        XCTAssertTrue(isValid)
    }
}

// MARK: - Relay Message Tests

final class RelayMessageTests: XCTestCase {

    func testRegisterPayloadEncodeDecode() throws {
        let payload = RelayMessage.RegisterPayload(
            nodeID: "abc123",
            publicKey: "def456",
            displayName: "Test Node",
            capabilities: NodeCapabilities(
                hardware: .init(
                    chipFamily: .m2Pro,
                    chipName: "Apple M2 Pro",
                    totalRAMGB: 32,
                    gpuCoreCount: 19,
                    memoryBandwidthGBs: 200,
                    tier: .tier2
                ),
                loadedModels: ["model-a"],
                maxModelSizeGB: 28,
                isAvailable: true
            ),
            signature: "sig789"
        )

        let message = RelayMessage.register(payload)

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)

        if case .register(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.nodeID, "abc123")
            XCTAssertEqual(decodedPayload.publicKey, "def456")
            XCTAssertEqual(decodedPayload.displayName, "Test Node")
            XCTAssertEqual(decodedPayload.capabilities.loadedModels, ["model-a"])
            XCTAssertEqual(decodedPayload.capabilities.hardware.totalRAMGB, 32)
        } else {
            XCTFail("Decoded message should be .register")
        }
    }

    func testDiscoverPayloadEncodeDecode() throws {
        let payload = RelayMessage.DiscoverPayload(
            requestingNodeID: "node1",
            filter: PeerFilter(modelID: "llama-3", minRAMGB: 16)
        )

        let message = RelayMessage.discover(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)

        if case .discover(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.requestingNodeID, "node1")
            XCTAssertEqual(decodedPayload.filter?.modelID, "llama-3")
            XCTAssertEqual(decodedPayload.filter?.minRAMGB, 16)
        } else {
            XCTFail("Decoded message should be .discover")
        }
    }

    func testOfferPayloadEncodeDecode() throws {
        let payload = RelayMessage.OfferPayload(
            fromNodeID: "nodeA",
            toNodeID: "nodeB",
            sessionID: "session1",
            connectionInfo: ConnectionInfo(
                publicIP: "1.2.3.4",
                publicPort: 12345,
                natType: .portRestricted,
                quicParameters: QUICParameters(certificateFingerprint: "abc")
            ),
            signature: "sig"
        )

        let message = RelayMessage.offer(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)

        if case .offer(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.fromNodeID, "nodeA")
            XCTAssertEqual(decodedPayload.connectionInfo.publicIP, "1.2.3.4")
            XCTAssertEqual(decodedPayload.connectionInfo.publicPort, 12345)
            XCTAssertEqual(decodedPayload.connectionInfo.natType, .portRestricted)
        } else {
            XCTFail("Decoded message should be .offer")
        }
    }

    func testAllMessageTypesRoundTrip() throws {
        let messages: [RelayMessage] = [
            .registerAck(.init(nodeID: "n1", ttlSeconds: 300)),
            .discoverResponse(.init(peers: [])),
            .iceCandidate(.init(
                fromNodeID: "a", toNodeID: "b", sessionID: "s",
                candidate: ICECandidate(ip: "1.2.3.4", port: 1234, type: .host, priority: 100)
            )),
            .peerJoined(.init(nodeID: "n1", displayName: "Test")),
            .peerLeft(.init(nodeID: "n2", displayName: "Gone")),
            .error(.init(code: "E001", message: "Something failed")),
        ]

        for message in messages {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)
            // Just verify it doesn't throw
            _ = decoded
        }
    }
}

// MARK: - STUN Client Tests

final class STUNClientTests: XCTestCase {

    func testBuildBindingRequest() {
        let request = STUNClient.buildBindingRequest()

        // STUN header is 20 bytes
        XCTAssertEqual(request.count, 20)

        // Message type: Binding Request (0x0001)
        XCTAssertEqual(request.readUInt16(at: 0), 0x0001)

        // Message length: 0 (no attributes)
        XCTAssertEqual(request.readUInt16(at: 2), 0)

        // Magic cookie: 0x2112A442
        XCTAssertEqual(request.readUInt32(at: 4), 0x2112A442)
    }

    func testParseBindingResponse_XorMappedAddress() throws {
        // Build a minimal STUN Binding Response with XOR-MAPPED-ADDRESS
        var response = Data(capacity: 32)

        // Message type: Binding Response (0x0101)
        var msgType: UInt16 = 0x0101
        response.append(contentsOf: Data(bytes: &msgType, count: 2).reversed())

        // Message length: 12 (one attribute: type(2) + length(2) + value(8))
        var msgLen: UInt16 = 12
        response.append(contentsOf: Data(bytes: &msgLen, count: 2).reversed())

        // Magic cookie: 0x2112A442
        var cookie: UInt32 = 0x2112A442
        response.append(contentsOf: Data(bytes: &cookie, count: 4).reversed())

        // Transaction ID: 12 bytes of zeros
        response.append(Data(count: 12))

        // XOR-MAPPED-ADDRESS attribute
        // Type: 0x0020
        var attrType: UInt16 = 0x0020
        response.append(contentsOf: Data(bytes: &attrType, count: 2).reversed())

        // Length: 8
        var attrLen: UInt16 = 8
        response.append(contentsOf: Data(bytes: &attrLen, count: 2).reversed())

        // Reserved byte + Family (0x01 = IPv4)
        response.append(0x00)
        response.append(0x01)

        // XOR Port: port 8080 XOR'd with top 16 bits of magic cookie
        // 8080 = 0x1F90, magic cookie top = 0x2112
        // 0x1F90 XOR 0x2112 = 0x3E82
        var xorPort: UInt16 = 0x3E82
        response.append(contentsOf: Data(bytes: &xorPort, count: 2).reversed())

        // XOR Address: 192.168.1.100 XOR'd with magic cookie
        // 192.168.1.100 = 0xC0A80164
        // 0xC0A80164 XOR 0x2112A442 = 0xE1BAA526
        var xorAddr: UInt32 = 0xE1BAA526
        response.append(contentsOf: Data(bytes: &xorAddr, count: 4).reversed())

        let mapping = try STUNClient.parseBindingResponse(response)

        XCTAssertEqual(mapping.publicIP, "192.168.1.100")
        XCTAssertEqual(mapping.publicPort, 8080)
    }

    func testParseBindingResponseTooShort() {
        let shortData = Data(count: 10)

        XCTAssertThrowsError(try STUNClient.parseBindingResponse(shortData)) { error in
            if let wanError = error as? WANError {
                XCTAssertNotNil(wanError.errorDescription)
            }
        }
    }

    func testParseBindingResponseWrongType() {
        // Build response with wrong message type
        var data = Data(count: 20)
        // Set message type to 0x0003 (not a binding response)
        data[0] = 0x00
        data[1] = 0x03
        // Set magic cookie
        data[4] = 0x21
        data[5] = 0x12
        data[6] = 0xA4
        data[7] = 0x42

        XCTAssertThrowsError(try STUNClient.parseBindingResponse(data))
    }
}

// MARK: - NAT Type Tests

final class NATTypeTests: XCTestCase {

    func testCanHolePunch() {
        XCTAssertTrue(NATType.fullCone.canHolePunch)
        XCTAssertTrue(NATType.restrictedCone.canHolePunch)
        XCTAssertTrue(NATType.portRestricted.canHolePunch)
        XCTAssertFalse(NATType.symmetric.canHolePunch)
        XCTAssertFalse(NATType.unknown.canHolePunch)
    }

    func testNATTypeCodable() throws {
        let types: [NATType] = [.fullCone, .restrictedCone, .portRestricted, .symmetric, .unknown]

        for natType in types {
            let data = try JSONEncoder().encode(natType)
            let decoded = try JSONDecoder().decode(NATType.self, from: data)
            XCTAssertEqual(decoded, natType)
        }
    }
}

// MARK: - Data Hex Extension Tests

final class DataHexTests: XCTestCase {

    func testHexStringInit() {
        let data = Data(hexString: "48656c6c6f")
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), "Hello")
    }

    func testHexStringInitWithPrefix() {
        let data = Data(hexString: "0x48656c6c6f")
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), "Hello")
    }

    func testHexStringInitOddLength() {
        let data = Data(hexString: "abc")
        XCTAssertNil(data)
    }

    func testHexStringInitInvalidChars() {
        let data = Data(hexString: "zzzz")
        XCTAssertNil(data)
    }

    func testHexStringEmpty() {
        let data = Data(hexString: "")
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 0)
    }
}

// MARK: - WANPeerInfo Tests

final class WANPeerInfoTests: XCTestCase {

    func testHasModel() {
        let peer = WANPeerInfo(
            nodeID: "test",
            publicKey: "key",
            displayName: "Test",
            capabilities: NodeCapabilities(
                hardware: .init(
                    chipFamily: .m3Max,
                    chipName: "Apple M3 Max",
                    totalRAMGB: 64,
                    gpuCoreCount: 40,
                    memoryBandwidthGBs: 400,
                    tier: .tier1
                ),
                loadedModels: ["llama-3-8b", "mistral-7b"]
            )
        )

        XCTAssertTrue(peer.hasModel("llama-3-8b"))
        XCTAssertTrue(peer.hasModel("mistral-7b"))
        XCTAssertFalse(peer.hasModel("gpt-4"))
    }

    func testCodable() throws {
        let peer = WANPeerInfo(
            nodeID: "node1",
            publicKey: "pubkey1",
            displayName: "My Mac",
            capabilities: NodeCapabilities(
                hardware: .init(
                    chipFamily: .m2,
                    chipName: "Apple M2",
                    totalRAMGB: 16,
                    gpuCoreCount: 10,
                    memoryBandwidthGBs: 100,
                    tier: .tier2
                )
            ),
            natType: .portRestricted,
            endpoints: [
                PeerEndpoint(ip: "1.2.3.4", port: 5678, type: .publicIPv4)
            ]
        )

        let data = try JSONEncoder().encode(peer)
        let decoded = try JSONDecoder().decode(WANPeerInfo.self, from: data)

        XCTAssertEqual(decoded.nodeID, "node1")
        XCTAssertEqual(decoded.displayName, "My Mac")
        XCTAssertEqual(decoded.natType, .portRestricted)
        XCTAssertEqual(decoded.endpoints.count, 1)
        XCTAssertEqual(decoded.endpoints.first?.ip, "1.2.3.4")
    }
}

// MARK: - ConnectionInfo Tests

final class ConnectionInfoTests: XCTestCase {

    func testCodable() throws {
        let info = ConnectionInfo(
            publicIP: "203.0.113.5",
            publicPort: 4433,
            localIP: "192.168.1.10",
            localPort: 4433,
            natType: .fullCone,
            quicParameters: QUICParameters(
                alpn: ["solair-wan-1"],
                certificateFingerprint: "abc123"
            )
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ConnectionInfo.self, from: data)

        XCTAssertEqual(decoded.publicIP, "203.0.113.5")
        XCTAssertEqual(decoded.publicPort, 4433)
        XCTAssertEqual(decoded.localIP, "192.168.1.10")
        XCTAssertEqual(decoded.natType, .fullCone)
        XCTAssertEqual(decoded.quicParameters?.alpn, ["solair-wan-1"])
    }
}

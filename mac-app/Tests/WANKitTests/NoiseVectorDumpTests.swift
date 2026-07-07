import XCTest
import CryptoKit
@testable import WANKit

/// Golden-vector generator + self-check for the Noise_IK transport.
///
/// The JSON printed by `testDumpGoldenVectors` is committed as
/// `protocol/tests/fixtures/noise_vectors.json` and replayed byte-for-byte
/// by the Rust implementation in `node/src/pin/noise.rs`. If this test's
/// output ever changes, the Rust suite must be regenerated in lockstep —
/// a mismatch means the two platforms can no longer talk to each other.
final class NoiseVectorDumpTests: XCTestCase {

    private func key(_ byte: UInt8) -> Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testDumpGoldenVectors() throws {
        let initiatorStatic = key(0x11)
        let responderStatic = key(0x22)
        let initiatorEphemeral = key(0x33)
        let responderEphemeral = key(0x44)
        // Fixed 12-byte handshake payloads (production uses timestamps;
        // length is what matters for framing).
        let initiatorPayload = Data("i-payload-01".utf8)
        let responderPayload = Data("r-payload-02".utf8)

        let (message1, state) = try NoiseHandshake.initiatorBegin(
            localStatic: initiatorStatic,
            remoteStaticPublic: responderStatic.publicKey,
            ephemeral: initiatorEphemeral,
            payload: initiatorPayload
        )

        let (message2, responderKeys, learnedInitiatorStatic) = try NoiseHandshake.responderComplete(
            localStatic: responderStatic,
            message1: message1,
            ephemeral: responderEphemeral,
            payload: responderPayload
        )
        XCTAssertEqual(
            learnedInitiatorStatic.rawRepresentation,
            initiatorStatic.publicKey.rawRepresentation
        )

        let initiatorKeys = try NoiseHandshake.initiatorFinish(state: state, message2: message2)
        XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey)
        XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey)
        XCTAssertEqual(initiatorKeys.handshakeHash, responderKeys.handshakeHash)

        // Transport vectors: two i→r packets (nonces 0,1) and one r→i.
        let initiatorSession = NoiseSession(keys: initiatorKeys)
        let responderSession = NoiseSession(keys: responderKeys)
        let i2r0 = try initiatorSession.encrypt(Data("pin-vector-i2r".utf8))
        let i2r1 = try initiatorSession.encrypt(Data("pin-vector-i2r-again".utf8))
        let r2i0 = try responderSession.encrypt(Data("pin-vector-r2i".utf8))
        XCTAssertEqual(try responderSession.decrypt(i2r0), Data("pin-vector-i2r".utf8))
        XCTAssertEqual(try responderSession.decrypt(i2r1), Data("pin-vector-i2r-again".utf8))
        XCTAssertEqual(try initiatorSession.decrypt(r2i0), Data("pin-vector-r2i".utf8))

        let vectors: [String: Any] = [
            "notes": [
                "protocol": "Noise_IK_25519_ChaChaPoly_BLAKE2s",
                "dh": "X25519 output passed through HKDF-SHA256(salt=empty, info=empty, len=32) — CryptoKit cannot expose raw shared secrets, so this wrapper IS the wire format",
                "msg2_se_deviation": "msg2's 'se' token re-mixes DH(initiator_ephemeral, responder_static) — i.e. a repeat of 'es' — instead of standard IK's DH(initiator_static, responder_ephemeral). Both deployed sides agree; do NOT fix one side alone",
                "handshake_nonce": "every handshake AEAD uses nonce 0 (fresh key per encryption)",
                "aead_nonce_layout": "12 bytes: 4 zero bytes then 8-byte little-endian counter",
                "transport_packet": "[8-byte LE counter][ciphertext][16-byte tag], AD empty",
                "hkdf": "Noise HKDF with HMAC-BLAKE2s-256 (block size 64)",
            ],
            "initiatorStaticPrivate": hex(Data(repeating: 0x11, count: 32)),
            "initiatorStaticPublic": hex(initiatorStatic.publicKey.rawRepresentation),
            "responderStaticPrivate": hex(Data(repeating: 0x22, count: 32)),
            "responderStaticPublic": hex(responderStatic.publicKey.rawRepresentation),
            "initiatorEphemeralPrivate": hex(Data(repeating: 0x33, count: 32)),
            "responderEphemeralPrivate": hex(Data(repeating: 0x44, count: 32)),
            "initiatorHandshakePayload": hex(initiatorPayload),
            "responderHandshakePayload": hex(responderPayload),
            "message1": hex(message1),
            "message2": hex(message2),
            "initiatorSendKey": hex(initiatorKeys.sendKey),
            "initiatorReceiveKey": hex(initiatorKeys.receiveKey),
            "handshakeHash": hex(initiatorKeys.handshakeHash),
            "transportI2R_0": hex(i2r0),
            "transportI2R_1": hex(i2r1),
            "transportR2I_0": hex(r2i0),
        ]
        let json = try JSONSerialization.data(
            withJSONObject: vectors,
            options: [.prettyPrinted, .sortedKeys]
        )
        print("NOISE_VECTORS_BEGIN")
        print(String(data: json, encoding: .utf8)!)
        print("NOISE_VECTORS_END")
    }

    /// Determinism guard: rerunning the fixed-key handshake must reproduce
    /// identical bytes (no hidden randomness or timestamps).
    func testFixedKeyHandshakeIsDeterministic() throws {
        func run() throws -> (Data, Data) {
            let (m1, st) = try NoiseHandshake.initiatorBegin(
                localStatic: key(0x11),
                remoteStaticPublic: key(0x22).publicKey,
                ephemeral: key(0x33),
                payload: Data("i-payload-01".utf8)
            )
            let (m2, _, _) = try NoiseHandshake.responderComplete(
                localStatic: key(0x22),
                message1: m1,
                ephemeral: key(0x44),
                payload: Data("r-payload-02".utf8)
            )
            _ = try NoiseHandshake.initiatorFinish(state: st, message2: m2)
            return (m1, m2)
        }
        let (a1, a2) = try run()
        let (b1, b2) = try run()
        XCTAssertEqual(a1, b1)
        XCTAssertEqual(a2, b2)
    }
}

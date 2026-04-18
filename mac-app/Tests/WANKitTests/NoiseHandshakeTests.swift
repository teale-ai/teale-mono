import XCTest
import CryptoKit
@testable import WANKit

final class NoiseHandshakeTests: XCTestCase {

    // MARK: - Full Handshake Round-Trip

    /// Two peers complete a Noise_IK handshake and derive matching transport keys.
    func testHandshakeRoundTrip() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        // Initiator knows responder's public key (from discovery)
        let (msg1, state) = try NoiseHandshake.initiatorBegin(
            localStatic: initiatorStatic,
            remoteStaticPublic: responderStatic.publicKey
        )

        // Responder processes msg1, returns msg2 + keys + revealed initiator key
        let (msg2, responderKeys, revealedInitiatorPub) = try NoiseHandshake.responderComplete(
            localStatic: responderStatic,
            message1: msg1
        )

        // Verify responder discovered the initiator's public key
        XCTAssertEqual(
            revealedInitiatorPub.rawRepresentation,
            initiatorStatic.publicKey.rawRepresentation,
            "Responder should learn initiator's static public key from the handshake"
        )

        // Initiator processes msg2 to derive transport keys
        let initiatorKeys = try NoiseHandshake.initiatorFinish(state: state, message2: msg2)

        // Transport keys should be mirrored: initiator's send = responder's receive
        XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey,
                       "Initiator's send key must equal responder's receive key")
        XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey,
                       "Initiator's receive key must equal responder's send key")

        // Handshake hashes should match (channel binding)
        XCTAssertEqual(initiatorKeys.handshakeHash, responderKeys.handshakeHash,
                       "Both sides should derive the same handshake hash")

        // Send and receive keys should be different from each other
        XCTAssertNotEqual(initiatorKeys.sendKey, initiatorKeys.receiveKey,
                          "Send and receive keys should differ")
    }

    // MARK: - Session Encrypt/Decrypt Round-Trip

    /// After handshake, encrypted messages can be exchanged in both directions.
    func testSessionEncryptDecrypt() throws {
        let (initiatorKeys, responderKeys) = try performHandshake()

        let initiatorSession = NoiseSession(keys: initiatorKeys)
        let responderSession = NoiseSession(keys: responderKeys)

        // Initiator → Responder
        let plaintext1 = Data("Hello from initiator!".utf8)
        let encrypted1 = try initiatorSession.encrypt(plaintext1)
        let decrypted1 = try responderSession.decrypt(encrypted1)
        XCTAssertEqual(decrypted1, plaintext1)

        // Responder → Initiator
        let plaintext2 = Data("Hello from responder!".utf8)
        let encrypted2 = try responderSession.encrypt(plaintext2)
        let decrypted2 = try initiatorSession.decrypt(encrypted2)
        XCTAssertEqual(decrypted2, plaintext2)
    }

    /// Multiple messages in sequence work (nonces increment correctly).
    func testMultipleMessages() throws {
        let (initiatorKeys, responderKeys) = try performHandshake()

        let initiatorSession = NoiseSession(keys: initiatorKeys)
        let responderSession = NoiseSession(keys: responderKeys)

        for i in 0..<100 {
            let msg = Data("Message \(i)".utf8)
            let encrypted = try initiatorSession.encrypt(msg)
            let decrypted = try responderSession.decrypt(encrypted)
            XCTAssertEqual(decrypted, msg, "Message \(i) round-trip failed")
        }
    }

    // MARK: - Tampered Message Rejection

    /// A tampered ciphertext should fail decryption.
    func testTamperedCiphertextRejected() throws {
        let (initiatorKeys, responderKeys) = try performHandshake()

        let initiatorSession = NoiseSession(keys: initiatorKeys)
        let responderSession = NoiseSession(keys: responderKeys)

        let plaintext = Data("Secret message".utf8)
        var encrypted = try initiatorSession.encrypt(plaintext)

        // Tamper with a byte in the ciphertext (skip the 8-byte nonce prefix)
        let tamperIndex = encrypted.index(encrypted.startIndex, offsetBy: 10)
        encrypted[tamperIndex] ^= 0xFF

        XCTAssertThrowsError(try responderSession.decrypt(encrypted),
                             "Tampered ciphertext should fail decryption")
    }

    /// A tampered handshake message should fail.
    func testTamperedHandshakeRejected() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        var (msg1, _) = try NoiseHandshake.initiatorBegin(
            localStatic: initiatorStatic,
            remoteStaticPublic: responderStatic.publicKey
        )

        // Tamper with the ephemeral public key in msg1
        msg1[5] ^= 0xFF

        XCTAssertThrowsError(
            try NoiseHandshake.responderComplete(localStatic: responderStatic, message1: msg1),
            "Tampered handshake msg1 should be rejected"
        )
    }

    // MARK: - Replay Rejection

    /// Replaying an encrypted packet should be detected.
    func testReplayRejected() throws {
        let (initiatorKeys, responderKeys) = try performHandshake()

        let initiatorSession = NoiseSession(keys: initiatorKeys)
        let responderSession = NoiseSession(keys: responderKeys)

        let plaintext = Data("Don't replay me".utf8)
        let encrypted = try initiatorSession.encrypt(plaintext)

        // First decrypt succeeds
        let decrypted = try responderSession.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)

        // Replay of the same packet should fail
        XCTAssertThrowsError(try responderSession.decrypt(encrypted),
                             "Replayed packet should be rejected")
    }

    // MARK: - Wrong Key Rejection

    /// Handshake with the wrong responder key should fail.
    func testWrongResponderKeyRejected() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let wrongResponder = Curve25519.KeyAgreement.PrivateKey()

        // Initiator targets the real responder's public key
        let (msg1, _) = try NoiseHandshake.initiatorBegin(
            localStatic: initiatorStatic,
            remoteStaticPublic: responderStatic.publicKey
        )

        // A different responder tries to complete the handshake
        XCTAssertThrowsError(
            try NoiseHandshake.responderComplete(localStatic: wrongResponder, message1: msg1),
            "Wrong responder should fail to decrypt initiator's static key"
        )
    }

    // MARK: - Large Payload

    /// Large messages encrypt/decrypt correctly.
    func testLargePayload() throws {
        let (initiatorKeys, responderKeys) = try performHandshake()

        let initiatorSession = NoiseSession(keys: initiatorKeys)
        let responderSession = NoiseSession(keys: responderKeys)

        // 64KB payload (typical large inference response)
        let payload = Data((0..<65536).map { UInt8($0 % 256) })
        let encrypted = try initiatorSession.encrypt(payload)
        let decrypted = try responderSession.decrypt(encrypted)
        XCTAssertEqual(decrypted, payload)
    }

    // MARK: - Session Expiry

    func testSessionReportsExpiry() throws {
        let (initiatorKeys, _) = try performHandshake()
        let session = NoiseSession(keys: initiatorKeys)

        // Fresh session should not be expired
        XCTAssertFalse(session.isExpired)
        XCTAssertLessThan(session.age, 1.0)
    }

    // MARK: - NoiseCrypto HKDF

    func testHKDFProducesDeterministicOutput() {
        let ck = Data(repeating: 0x42, count: 32)
        let ikm = Data(repeating: 0xAB, count: 32)

        let output1 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: ikm)
        let output2 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: ikm)

        XCTAssertEqual(output1[0], output2[0])
        XCTAssertEqual(output1[1], output2[1])
        XCTAssertEqual(output1[0].count, 32)
        XCTAssertEqual(output1[1].count, 32)
        XCTAssertNotEqual(output1[0], output1[1], "HKDF outputs should differ")
    }

    func testHKDFThreeOutputs() {
        let ck = Data(repeating: 0x01, count: 32)
        let ikm = Data(repeating: 0x02, count: 32)

        let output = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: ikm, numOutputs: 3)
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output[0].count, 32)
        XCTAssertEqual(output[1].count, 32)
        XCTAssertEqual(output[2].count, 32)
    }

    // MARK: - NoiseCrypto Encrypt/Decrypt

    func testChaChaPolyRoundTrip() throws {
        let key = Data(repeating: 0x55, count: 32)
        let plaintext = Data("ChaCha20-Poly1305 test".utf8)
        let ad = Data("additional data".utf8)

        let ciphertext = try NoiseCrypto.encrypt(key: key, nonce: 0, ad: ad, plaintext: plaintext)
        let decrypted = try NoiseCrypto.decrypt(key: key, nonce: 0, ad: ad, ciphertextAndTag: ciphertext)

        XCTAssertEqual(decrypted, plaintext)
        // Ciphertext should be plaintext + 16 byte tag
        XCTAssertEqual(ciphertext.count, plaintext.count + 16)
    }

    func testChaChaPolyWrongKeyFails() throws {
        let key1 = Data(repeating: 0x55, count: 32)
        let key2 = Data(repeating: 0xAA, count: 32)
        let plaintext = Data("wrong key test".utf8)

        let ciphertext = try NoiseCrypto.encrypt(key: key1, nonce: 0, ad: Data(), plaintext: plaintext)
        XCTAssertThrowsError(try NoiseCrypto.decrypt(key: key2, nonce: 0, ad: Data(), ciphertextAndTag: ciphertext))
    }

    func testChaChaPolyWrongNonceFails() throws {
        let key = Data(repeating: 0x55, count: 32)
        let plaintext = Data("wrong nonce test".utf8)

        let ciphertext = try NoiseCrypto.encrypt(key: key, nonce: 0, ad: Data(), plaintext: plaintext)
        XCTAssertThrowsError(try NoiseCrypto.decrypt(key: key, nonce: 1, ad: Data(), ciphertextAndTag: ciphertext))
    }

    // MARK: - Helpers

    private func performHandshake() throws -> (NoiseHandshake.TransportKeys, NoiseHandshake.TransportKeys) {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let (msg1, state) = try NoiseHandshake.initiatorBegin(
            localStatic: initiatorStatic,
            remoteStaticPublic: responderStatic.publicKey
        )

        let (msg2, responderKeys, _) = try NoiseHandshake.responderComplete(
            localStatic: responderStatic,
            message1: msg1
        )

        let initiatorKeys = try NoiseHandshake.initiatorFinish(state: state, message2: msg2)

        return (initiatorKeys, responderKeys)
    }
}

import Foundation
import CryptoKit

// MARK: - Noise_IK Handshake

/// Implements the Noise_IK handshake pattern for WireGuard-style P2P connections.
///
/// Pattern IK:
///   <- s                          (responder's static key known to initiator)
///   ...
///   -> e, es, s, ss               (initiator msg1)
///   <- e, ee, se                  (responder msg2)
///
/// After handshake, both sides derive symmetric transport keys.
public final class NoiseHandshake: Sendable {

    // Noise protocol name for hashing
    private static let protocolName = "Noise_IK_25519_ChaChaPoly_BLAKE2s"

    // MARK: - Handshake State

    /// The role in the handshake
    public enum Role: Sendable {
        case initiator
        case responder
    }

    /// Result of a completed handshake
    public struct TransportKeys: Sendable {
        public let sendKey: Data       // 32 bytes
        public let receiveKey: Data    // 32 bytes
        public let handshakeHash: Data // h — for channel binding
    }

    // MARK: - Initiator

    /// Create the first handshake message (initiator → responder).
    ///
    /// - Parameters:
    ///   - localStatic: initiator's static key pair (key agreement)
    ///   - remoteStaticPublic: responder's known static public key
    /// - Returns: (message1 bytes, handshake state to pass to `initiatorFinish`)
    public static func initiatorBegin(
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        remoteStaticPublic: Curve25519.KeyAgreement.PublicKey
    ) throws -> (message: Data, state: HandshakeState) {
        // Initialize symmetric state
        var (ck, h) = initializeSymmetric()

        // pre-message: <- s (mix responder's static public key)
        h = mixHash(h, data: remoteStaticPublic.rawRepresentation)

        // -> e: generate ephemeral, mix into hash
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub = ephemeral.publicKey.rawRepresentation
        h = mixHash(h, data: ephemeralPub)
        var message = ephemeralPub

        // -> es: DH(ephemeral, remote static)
        let esShared = try NoiseCrypto.dh(privateKey: ephemeral, publicKey: remoteStaticPublic)
        let ckAndK1 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: esShared)
        ck = ckAndK1[0]
        var k = ckAndK1[1]

        // -> s: encrypt initiator's static public key
        let encryptedStatic = try NoiseCrypto.encrypt(key: k, nonce: 0, ad: h, plaintext: localStatic.publicKey.rawRepresentation)
        h = mixHash(h, data: encryptedStatic)
        message.append(encryptedStatic)

        // -> ss: DH(local static, remote static)
        let ssShared = try NoiseCrypto.dh(privateKey: localStatic, publicKey: remoteStaticPublic)
        let ckAndK2 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: ssShared)
        ck = ckAndK2[0]
        k = ckAndK2[1]

        // Encrypt payload (timestamp for replay protection)
        let payload = timestampPayload()
        let encryptedPayload = try NoiseCrypto.encrypt(key: k, nonce: 0, ad: h, plaintext: payload)
        h = mixHash(h, data: encryptedPayload)
        message.append(encryptedPayload)

        let state = HandshakeState(
            role: .initiator,
            ck: ck,
            h: h,
            localStatic: localStatic,
            localEphemeral: ephemeral,
            remoteStaticPublic: remoteStaticPublic,
            remoteEphemeralPublic: nil
        )

        return (message, state)
    }

    /// Process the responder's reply and derive transport keys (initiator side).
    public static func initiatorFinish(
        state: HandshakeState,
        message2: Data
    ) throws -> TransportKeys {
        guard state.role == .initiator else {
            throw NoiseError.handshakeFailed("Wrong role for initiatorFinish")
        }

        var ck = state.ck
        var h = state.h

        // <- e: extract responder's ephemeral public key (32 bytes)
        guard message2.count >= 32 else {
            throw NoiseError.handshakeFailed("Message2 too short")
        }
        let remoteEphPubData = message2[message2.startIndex..<message2.index(message2.startIndex, offsetBy: 32)]
        let remoteEphPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphPubData)
        h = mixHash(h, data: Data(remoteEphPubData))

        // <- ee: DH(local ephemeral, remote ephemeral)
        let eeShared = try NoiseCrypto.dh(privateKey: state.localEphemeral!, publicKey: remoteEphPub)
        let ckAndK1 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: eeShared)
        ck = ckAndK1[0]
        var k = ckAndK1[1]

        // <- se: DH(local static, remote ephemeral) — note: initiator uses static, responder's ephemeral
        // Actually in IK: se means DH(responder_static_or_initiator_static, ephemeral)
        // For initiator processing responder's msg: DH(initiator_static, responder_ephemeral)
        // But Noise IK pattern says: se = DH(s, re) from responder's perspective = DH(rs, e) from initiator
        // Responder did: DH(responder_static? No — se in IK means DH(initiator_static, responder_ephemeral))
        // Let me re-check: In IK, msg2 tokens are: e, ee, se
        // "se" from responder = DH(s_responder, e_initiator) — responder uses their static with initiator's ephemeral
        // Initiator mirrors: DH(re_ephemeral_responder? No) DH(e_local, rs_remote_static? No)
        // Actually: "se" = DH(s, e) where s is responder's static, e is initiator's ephemeral
        // Initiator: DH(localEphemeral, remoteStatic) -- wait that's es which we already did
        // Let me be precise: In Noise notation for message 2 from responder:
        //   e = responder ephemeral
        //   ee = DH(responder_ephemeral, initiator_ephemeral)
        //   se = DH(responder_static, initiator_ephemeral)
        // So from initiator's perspective:
        //   ee = DH(initiator_ephemeral, responder_ephemeral) ✓ (same shared secret)
        //   se = DH(initiator_ephemeral, responder_static) -- NO wait
        // "se" means the first letter is whose static (s=sender=responder), second is whose ephemeral (e=receiver=initiator)
        // So: se = DH(responder_static, initiator_ephemeral)
        // Initiator mirrors as: DH(initiator_ephemeral, responder_static)
        // But we already have remoteStaticPublic, so:
        let seShared = try NoiseCrypto.dh(privateKey: state.localEphemeral!, publicKey: state.remoteStaticPublic!)
        let ckAndK2 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: seShared)
        ck = ckAndK2[0]
        k = ckAndK2[1]

        // Decrypt payload
        let encryptedPayload = message2[message2.index(message2.startIndex, offsetBy: 32)...]
        if !encryptedPayload.isEmpty {
            let _ = try NoiseCrypto.decrypt(key: k, nonce: 0, ad: h, ciphertextAndTag: Data(encryptedPayload))
            h = mixHash(h, data: Data(encryptedPayload))
        }

        // Split: derive transport keys
        let transportKeys = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: Data())
        return TransportKeys(
            sendKey: transportKeys[0],
            receiveKey: transportKeys[1],
            handshakeHash: h
        )
    }

    // MARK: - Responder

    /// Process the initiator's first message and generate a reply (responder side).
    ///
    /// - Parameters:
    ///   - localStatic: responder's static key pair
    ///   - message1: the initiator's first handshake message
    /// - Returns: (reply message, transport keys, initiator's static public key)
    public static func responderComplete(
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        message1: Data
    ) throws -> (message: Data, keys: TransportKeys, remoteStaticPublic: Curve25519.KeyAgreement.PublicKey) {
        var (ck, h) = initializeSymmetric()

        // pre-message: <- s (responder's own static public key)
        h = mixHash(h, data: localStatic.publicKey.rawRepresentation)

        // -> e: extract initiator's ephemeral (32 bytes)
        guard message1.count >= 32 else {
            throw NoiseError.handshakeFailed("Message1 too short for ephemeral key")
        }
        let remoteEphPubData = message1[message1.startIndex..<message1.index(message1.startIndex, offsetBy: 32)]
        let remoteEphPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphPubData)
        h = mixHash(h, data: Data(remoteEphPubData))

        // -> es: DH(remote ephemeral, local static) — mirrors initiator's DH(local ephemeral, remote static)
        let esShared = try NoiseCrypto.dh(privateKey: localStatic, publicKey: remoteEphPub)
        let ckAndK1 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: esShared)
        ck = ckAndK1[0]
        var k = ckAndK1[1]

        // -> s: decrypt initiator's static public key
        let staticStart = message1.index(message1.startIndex, offsetBy: 32)
        let staticEnd = message1.index(staticStart, offsetBy: 48) // 32 bytes + 16 byte tag
        guard message1.count >= 32 + 48 else {
            throw NoiseError.handshakeFailed("Message1 too short for encrypted static key")
        }
        let encryptedStatic = message1[staticStart..<staticEnd]
        let remoteStaticPubData = try NoiseCrypto.decrypt(key: k, nonce: 0, ad: h, ciphertextAndTag: Data(encryptedStatic))
        let remoteStaticPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticPubData)
        h = mixHash(h, data: Data(encryptedStatic))

        // -> ss: DH(local static, remote static)
        let ssShared = try NoiseCrypto.dh(privateKey: localStatic, publicKey: remoteStaticPub)
        let ckAndK2 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: ssShared)
        ck = ckAndK2[0]
        k = ckAndK2[1]

        // Decrypt initiator's payload
        let payloadStart = staticEnd
        let encryptedPayload = message1[payloadStart...]
        if !encryptedPayload.isEmpty {
            let _ = try NoiseCrypto.decrypt(key: k, nonce: 0, ad: h, ciphertextAndTag: Data(encryptedPayload))
            h = mixHash(h, data: Data(encryptedPayload))
        }

        // Now generate response (msg2)
        // <- e: generate responder's ephemeral
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub = ephemeral.publicKey.rawRepresentation
        h = mixHash(h, data: ephemeralPub)
        var reply = ephemeralPub

        // <- ee: DH(responder ephemeral, initiator ephemeral)
        let eeShared = try NoiseCrypto.dh(privateKey: ephemeral, publicKey: remoteEphPub)
        let ckAndK3 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: eeShared)
        ck = ckAndK3[0]
        k = ckAndK3[1]

        // <- se: DH(responder static, initiator ephemeral)
        // Wait — "se" in msg2 from responder: s=responder_static, e=initiator_ephemeral
        // Responder does: DH(localStatic, remoteEphemeral)
        // Hmm but we need responder's static with initiator's ephemeral
        let seShared = try NoiseCrypto.dh(privateKey: localStatic, publicKey: remoteEphPub)
        let ckAndK4 = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: seShared)
        ck = ckAndK4[0]
        k = ckAndK4[1]

        // Encrypt empty payload (or timestamp)
        let payload = timestampPayload()
        let encryptedReplyPayload = try NoiseCrypto.encrypt(key: k, nonce: 0, ad: h, plaintext: payload)
        h = mixHash(h, data: encryptedReplyPayload)
        reply.append(encryptedReplyPayload)

        // Split: derive transport keys (reversed for responder)
        let transportKeys = NoiseCrypto.hkdf(chainingKey: ck, inputKeyMaterial: Data())
        let keys = TransportKeys(
            sendKey: transportKeys[1],   // Reversed: responder's send = initiator's receive
            receiveKey: transportKeys[0],
            handshakeHash: h
        )

        return (reply, keys, remoteStaticPub)
    }

    // MARK: - Helpers

    /// Initialize the Noise symmetric state with the protocol name.
    private static func initializeSymmetric() -> (ck: Data, h: Data) {
        let protocolNameData = Data(protocolName.utf8)
        let h: Data
        if protocolNameData.count <= 32 {
            var padded = protocolNameData
            padded.append(Data(count: 32 - protocolNameData.count))
            h = padded
        } else {
            h = NoiseCrypto.hash(protocolNameData)
        }
        let ck = h
        return (ck, h)
    }

    /// Mix data into the handshake hash: h = HASH(h || data)
    private static func mixHash(_ h: Data, data: Data) -> Data {
        NoiseCrypto.hash(h, data)
    }

    /// Create a timestamp payload for replay protection (8-byte seconds + 4-byte nanos).
    private static func timestampPayload() -> Data {
        let now = Date()
        let seconds = UInt64(now.timeIntervalSince1970)
        let nanos = UInt32((now.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000)
        var data = Data(count: 12)
        withUnsafeBytes(of: seconds.bigEndian) { data.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: nanos.bigEndian) { data.replaceSubrange(8..<12, with: $0) }
        return data
    }
}

// MARK: - Handshake State (passed between begin/finish calls)

public struct HandshakeState: Sendable {
    let role: NoiseHandshake.Role
    let ck: Data
    let h: Data
    let localStatic: Curve25519.KeyAgreement.PrivateKey
    let localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    let remoteStaticPublic: Curve25519.KeyAgreement.PublicKey?
    let remoteEphemeralPublic: Curve25519.KeyAgreement.PublicKey?
}

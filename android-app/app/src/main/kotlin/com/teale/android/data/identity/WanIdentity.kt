package com.teale.android.data.identity

import net.i2p.crypto.eddsa.EdDSAEngine
import net.i2p.crypto.eddsa.EdDSAPrivateKey
import net.i2p.crypto.eddsa.EdDSAPublicKey
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable
import net.i2p.crypto.eddsa.spec.EdDSAPrivateKeySpec
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Ed25519 identity. `deviceID` = lowercase hex of the public key — same convention
 * as the Rust node (`node/src/identity.rs`) and Swift `AuthKit`.
 */
class WanIdentity(private val storage: KeyStorage) {

    private val curveSpec = EdDSANamedCurveTable.getByName(EdDSANamedCurveTable.ED_25519)

    private var cachedPrivate: ByteArray? = null
    private var cachedPublic: ByteArray? = null

    /** 32-byte seed (the "private key material") */
    fun privateSeed(): ByteArray = ensure().first

    /** 32-byte public key */
    fun publicKey(): ByteArray = ensure().second

    /** Lowercase hex of the public key — this is the gateway-facing deviceID. */
    fun deviceId(): String = publicKey().toHexLower()

    /** Sign arbitrary bytes. */
    fun sign(message: ByteArray): ByteArray {
        val seed = privateSeed()
        val spec = EdDSAPrivateKeySpec(seed, curveSpec)
        val sk = EdDSAPrivateKey(spec)
        val engine = EdDSAEngine(MessageDigest.getInstance(curveSpec.hashAlgorithm))
        engine.initSign(sk)
        engine.update(message)
        return engine.sign()
    }

    /** Verify (used in tests) */
    fun verify(message: ByteArray, signature: ByteArray): Boolean {
        val pk = EdDSAPublicKey(EdDSAPublicKeySpec(publicKey(), curveSpec))
        val engine = EdDSAEngine(MessageDigest.getInstance(curveSpec.hashAlgorithm))
        engine.initVerify(pk)
        engine.update(message)
        return engine.verify(signature)
    }

    @Synchronized
    private fun ensure(): Pair<ByteArray, ByteArray> {
        cachedPrivate?.let { priv ->
            cachedPublic?.let { pub -> return priv to pub }
        }
        val existingSeed = storage.getBytes(KEY_SEED)
        val existingPub = storage.getBytes(KEY_PUB)
        if (existingSeed != null && existingPub != null) {
            cachedPrivate = existingSeed
            cachedPublic = existingPub
            return existingSeed to existingPub
        }
        val seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val spec = EdDSAPrivateKeySpec(seed, curveSpec)
        val sk = EdDSAPrivateKey(spec)
        val pub = sk.abyte // precomputed public key bytes
        storage.putBytes(KEY_SEED, seed)
        storage.putBytes(KEY_PUB, pub)
        cachedPrivate = seed
        cachedPublic = pub
        return seed to pub
    }

    companion object {
        private const val KEY_SEED = "wan_seed"
        private const val KEY_PUB = "wan_pub"
    }
}

fun ByteArray.toHexLower(): String =
    joinToString(separator = "") { String.format("%02x", it) }

fun String.hexToBytes(): ByteArray {
    val clean = if (length % 2 == 0) this else "0$this"
    return ByteArray(clean.length / 2) { i ->
        clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
    }
}

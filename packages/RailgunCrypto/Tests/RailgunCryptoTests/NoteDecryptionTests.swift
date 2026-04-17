import Testing
import BigInt
import Foundation
import CryptoKit
@testable import RailgunCrypto

/// Test vectors generated from @railgun-community/engine and @noble/ed25519.
@Suite("Note Decryption")
struct NoteDecryptionTests {
    static let viewingPrivHex = "9a9e1ca3b9476dc8500b43f30f34104c92a3eedfd727757ffd0ad15da8e11572"
    static let blindedPubHex = "6fc05f4cfdccc1c0d02fa1637f074f6f71636c47546ff25b305899265d435560"

    // MARK: - Ed25519 point decompression

    @Test("Decompress and recompress Ed25519 point is identity")
    func decompressRecompress() {
        let pubData = Data(hexString: Self.blindedPubHex)!
        let point = Ed25519Curve.Point(compressed: pubData)
        let recompressed = point.compress()
        #expect(recompressed == pubData)
    }

    // MARK: - ECDH shared key

    @Test("ECDH scalar derivation matches SDK")
    func ecdhScalar() {
        // SHA-512 of viewing private key, first 32 bytes, clamped
        let viewingPriv = Data(hexString: Self.viewingPrivHex)!
        let hash = Data(CryptoKit.SHA512.hash(data: viewingPriv))
        let first32 = hash.prefix(32).hexString
        #expect(first32 == "9f8c56a6c172f070976d1302295593ef1ddf259a601aa4eeaa46f889a5819d84")
    }

    @Test("ECDH shared key matches SDK")
    func ecdhSharedKey() {
        let viewingPriv = Data(hexString: Self.viewingPrivHex)!
        let blindedPub = Data(hexString: Self.blindedPubHex)!

        let key = RailgunECDH.sharedKey(
            viewingPrivateKey: viewingPriv,
            blindedPublicKey: blindedPub
        )

        #expect(key != nil)
        #expect(key?.hexString == "d06e650ec2403acd44bcf988aaac339517dce1153eab36ed1ae74a3b5418dca5")
    }

    // MARK: - AES-256-GCM decryption

    @Test("AES-256-GCM decryption matches SDK")
    func aesGcmDecrypt() {
        let key = Data(hexString: "d06e650ec2403acd44bcf988aaac339517dce1153eab36ed1ae74a3b5418dca5")!
        let iv = Data(hexString: "e1e1a738363a7e6f304c686f7dcca7c2")!
        let tag = Data(hexString: "86fb9be299522dd15c2b259c0d0446b9")!
        let data = [
            Data(hexString: "80e2cd87c3da4eee05425c588c35e268ec3feb190f2de6c57f970e57def14a76")!,
            Data(hexString: "c0977f38815a862e8f409843db9aada017d6f370d5f32b53e48aa5f01ba1c179")!,
            Data(hexString: "8dba62d6d33e213a1dea8f2f8087361e2aa1fe6198627a177a3a17ecd1f7cf94")!,
        ]

        let decrypted = NoteDecryptor.aesGCMDecrypt(key: key, iv: iv, tag: tag, data: data)
        #expect(decrypted != nil)
        #expect(decrypted?.count == 3)

        // Block 0: 32 bytes of 0xAA (fake masterPublicKey)
        #expect(decrypted?[0] == Data(repeating: 0xAA, count: 32))
        // Block 1: 32 bytes of 0xBB (fake tokenHash)
        #expect(decrypted?[1] == Data(repeating: 0xBB, count: 32))
        // Block 2: 16 bytes of 0xCC + 16 bytes of 0x01
        let expectedBlock2 = Data(repeating: 0xCC, count: 16) + Data(repeating: 0x01, count: 16)
        #expect(decrypted?[2] == expectedBlock2)
    }

    @Test("AES-256-GCM with wrong key fails")
    func aesGcmWrongKey() {
        let key = Data(repeating: 0xFF, count: 32)  // Wrong key
        let iv = Data(hexString: "e1e1a738363a7e6f304c686f7dcca7c2")!
        let tag = Data(hexString: "86fb9be299522dd15c2b259c0d0446b9")!
        let data = [Data(hexString: "80e2cd87c3da4eee05425c588c35e268ec3feb190f2de6c57f970e57def14a76")!]

        let decrypted = NoteDecryptor.aesGCMDecrypt(key: key, iv: iv, tag: tag, data: data)
        #expect(decrypted == nil)
    }

    // MARK: - Ed25519 curve basics

    @Test("Ed25519 identity + identity = identity")
    func ed25519IdentityAdd() {
        let id = Ed25519Curve.Point.identity
        let result = Ed25519Curve.add(id, id)
        #expect(result.x == id.x)
        #expect(result.y == id.y)
    }

    @Test("Ed25519 scalar mul by 0 gives identity")
    func ed25519ScalarMulZero() {
        let point = Ed25519Curve.Point(compressed: Data(hexString: Self.blindedPubHex)!)
        let result = Ed25519Curve.scalarMul(point, 0)
        #expect(result.x == 0)
        #expect(result.y == 1)
    }

    @Test("Ed25519 scalar mul by 1 gives same point")
    func ed25519ScalarMulOne() {
        let pubData = Data(hexString: Self.blindedPubHex)!
        let point = Ed25519Curve.Point(compressed: pubData)
        let result = Ed25519Curve.scalarMul(point, 1)
        #expect(result.compress() == pubData)
    }
}

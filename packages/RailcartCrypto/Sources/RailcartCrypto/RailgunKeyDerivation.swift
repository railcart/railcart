import BigInt
import Foundation
import CryptoKit

/// RAILGUN key derivation from BIP39 mnemonic.
///
/// Derives spending (BabyJubJub), viewing (Ed25519), and nullifying (Poseidon) keys
/// using a custom BIP32 scheme with HMAC key "babyjubjub seed".
public enum RailgunKeyDerivation {
    /// All derived keys for a RAILGUN wallet.
    public struct KeySet: Sendable {
        public let spendingPrivateKey: Data   // 32 bytes
        public let spendingPublicKey: BabyJubJub.Point
        public let viewingPrivateKey: Data    // 32 bytes
        public let viewingPublicKey: Data     // 32 bytes (Ed25519)
        public let nullifyingKey: BigUInt
        public let masterPublicKey: BigUInt
    }

    /// BIP32 key node (chain key + chain code, both hex strings).
    struct KeyNode {
        let chainKey: String   // 64 hex chars = 32 bytes
        let chainCode: String  // 64 hex chars = 32 bytes
    }

    // MARK: - Public API

    /// Derive a full RAILGUN key set from a BIP39 seed (hex string) and derivation index.
    public static func deriveKeys(seed: String, index: Int = 0) -> KeySet {
        let master = getMasterKey(seed: seed)

        // Spending: m/44'/1984'/0'/0'/[index]'
        let spendingNode = derivePath(master, segments: [44, 1984, 0, 0, index])
        let spendingPriv = Data(hexString: spendingNode.chainKey)!
        let spendingPub = deriveSpendingPublicKey(privateKey: spendingPriv)

        // Viewing: m/420'/1984'/0'/0'/[index]'
        let viewingNode = derivePath(master, segments: [420, 1984, 0, 0, index])
        let viewingPriv = Data(hexString: viewingNode.chainKey)!
        let viewingPub = deriveViewingPublicKey(privateKey: viewingPriv)

        // Nullifying key: poseidon([viewing_private_key_as_bigint])
        let viewingPrivBigUInt = BigUInt(viewingNode.chainKey, radix: 16)!
        let nullifyingKey = Poseidon.hash([viewingPrivBigUInt])

        // Master public key: poseidon([spending_pub_x, spending_pub_y, nullifying_key])
        let masterPublicKey = Poseidon.hash([spendingPub.x, spendingPub.y, nullifyingKey])

        return KeySet(
            spendingPrivateKey: spendingPriv,
            spendingPublicKey: spendingPub,
            viewingPrivateKey: viewingPriv,
            viewingPublicKey: viewingPub,
            nullifyingKey: nullifyingKey,
            masterPublicKey: masterPublicKey
        )
    }

    // MARK: - BIP32 (babyjubjub seed)

    /// Derive master key from BIP39 seed using HMAC-SHA512 with key "babyjubjub seed".
    static func getMasterKey(seed: String) -> KeyNode {
        let key = "babyjubjub seed".data(using: .utf8)!
        let seedData = Data(hexString: seed)!
        let hmac = hmacSHA512(key: key, data: seedData)
        return KeyNode(
            chainKey: hmac.prefix(32).hexString,
            chainCode: hmac.suffix(32).hexString
        )
    }

    /// Derive a child key along a hardened path.
    static func derivePath(_ master: KeyNode, segments: [Int]) -> KeyNode {
        segments.reduce(master) { node, segment in
            deriveHardenedChild(node, index: segment)
        }
    }

    /// BIP32 hardened child key derivation.
    static func deriveHardenedChild(_ node: KeyNode, index: Int) -> KeyNode {
        let hardenedIndex = UInt32(index) + 0x80000000
        var indexBytes = Data(count: 4)
        indexBytes[0] = UInt8((hardenedIndex >> 24) & 0xFF)
        indexBytes[1] = UInt8((hardenedIndex >> 16) & 0xFF)
        indexBytes[2] = UInt8((hardenedIndex >> 8) & 0xFF)
        indexBytes[3] = UInt8(hardenedIndex & 0xFF)

        // preImage = 0x00 + chainKey + indexBytes
        var preImage = Data([0x00])
        preImage.append(Data(hexString: node.chainKey)!)
        preImage.append(indexBytes)

        let key = Data(hexString: node.chainCode)!
        let I = hmacSHA512(key: key, data: preImage)

        return KeyNode(
            chainKey: I.prefix(32).hexString,
            chainCode: I.suffix(32).hexString
        )
    }

    // MARK: - Spending Key (BabyJubJub EdDSA)

    /// Derive the BabyJubJub public spending key from a private key.
    ///
    /// Process: BLAKE-512(privKey) → prune first 32 bytes → little-endian to scalar → Base8 * (s >> 3)
    static func deriveSpendingPublicKey(privateKey: Data) -> BabyJubJub.Point {
        let hash = blake512(privateKey)
        var sBuff = Data(hash.prefix(32))

        // Prune buffer (same as circomlibjs pruneBuffer)
        sBuff[0] &= 0xF8
        sBuff[31] &= 0x7F
        sBuff[31] |= 0x40

        // Little-endian bytes to BigUInt
        let s = BigUInt(Data(sBuff.reversed()))

        // Multiply Base8 by (s >> 3)
        return BabyJubJub.mulPointScalar(BabyJubJub.base8, s >> 3)
    }

    // MARK: - Viewing Key (Ed25519)

    /// Derive the Ed25519 public viewing key from a private key.
    static func deriveViewingPublicKey(privateKey: Data) -> Data {
        // Ed25519 public key derivation. CryptoKit's Curve25519.Signing uses
        // the same Ed25519 curve as @noble/ed25519 in the SDK.
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
            preconditionFailure("Invalid Ed25519 private key")
        }
        return signingKey.publicKey.rawRepresentation
    }

    // MARK: - Crypto Helpers

    /// HMAC-SHA512.
    private static func hmacSHA512(key: Data, data: Data) -> Data {
        let hmac = HMAC<SHA512>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        )
        return Data(hmac)
    }

    /// BLAKE-512 hash (original BLAKE, NOT BLAKE2b).
    /// Used by circomlibjs EdDSA for BabyJubJub key derivation.
    private static func blake512(_ data: Data) -> Data {
        Blake512.hash(data)
    }
}

// MARK: - Data helpers

extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

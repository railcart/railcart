import BigInt
import Foundation

/// The type of a commitment in the RAILGUN merkle tree.
public enum CommitmentType: String, Sendable, Codable {
    case shieldCommitment = "ShieldCommitment"
    case transactCommitmentV2 = "TransactCommitment"
    case legacyGeneratedCommitment = "LegacyGeneratedCommitment"
    case legacyEncryptedCommitment = "LegacyEncryptedCommitment"
}

/// A transact commitment from the V2 RAILGUN contract.
public struct TransactCommitment: Sendable {
    public let hash: Data              // 32 bytes — the commitment hash (merkle leaf)
    public let txid: Data              // 32 bytes — Ethereum transaction hash
    public let blockNumber: Int
    public let timestamp: Int?
    public let ciphertext: CommitmentCiphertextV2
    public let utxoTree: Int
    public let utxoIndex: Int
}

/// A shield commitment from the V2 RAILGUN contract.
public struct ShieldCommitment: Sendable {
    public let hash: Data              // 32 bytes
    public let txid: Data              // 32 bytes
    public let blockNumber: Int
    public let timestamp: Int?
    /// Note preimage (not encrypted — shield data is public on-chain).
    public let preImage: ShieldPreImage
    /// Encrypted bundle: 3 × 32 bytes.
    public let encryptedBundle: [Data]
    /// Public key for deriving shared secret to decrypt the random.
    public let shieldKey: Data         // 32 bytes
    public let fee: BigUInt?
    public let utxoTree: Int
    public let utxoIndex: Int
}

/// Public shield preimage (the token, amount, and note public key are visible on-chain).
public struct ShieldPreImage: Sendable {
    public let npk: Data               // 32 bytes — note public key
    public let tokenType: Int          // 0 = ERC20
    public let tokenAddress: String    // checksummed address
    public let tokenSubID: BigUInt     // 0 for ERC20
    public let value: BigUInt
}

/// A nullifier event: marks a commitment as spent.
public struct NullifierEvent: Sendable {
    public let nullifier: Data         // 32 bytes
    public let treeNumber: Int
    public let txid: Data              // 32 bytes
    public let blockNumber: Int
}

/// An unshield event.
public struct UnshieldEvent: Sendable {
    public let txid: Data              // 32 bytes
    public let timestamp: Int?
    public let toAddress: String
    public let tokenType: Int
    public let tokenAddress: String
    public let tokenSubID: String
    public let amount: BigUInt
    public let fee: BigUInt
    public let blockNumber: Int
    public let eventLogIndex: Int?
}

/// All events returned from a quick-sync query.
public struct ScanEvents: Sendable {
    public let commitments: [ScanCommitment]
    public let nullifiers: [NullifierEvent]
    public let unshields: [UnshieldEvent]
}

/// A commitment from scanning (either shield or transact).
public enum ScanCommitment: Sendable {
    case shield(ShieldCommitment)
    case transact(TransactCommitment)
}

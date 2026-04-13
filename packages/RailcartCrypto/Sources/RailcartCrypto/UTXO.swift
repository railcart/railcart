import BigInt
import Foundation

/// A RAILGUN unspent transaction output (decrypted note owned by this wallet).
public struct UTXO: Sendable, Identifiable {
    public var id: String { "\(tree):\(position)" }

    /// Which merkle tree this UTXO lives in.
    public let tree: Int
    /// Position (leaf index) within the tree.
    public let position: Int
    /// The commitment hash (merkle leaf value).
    public let hash: Data
    /// Ethereum transaction hash that created this commitment.
    public let txid: Data
    /// Block number when created.
    public let blockNumber: Int

    /// The decrypted note data.
    public let tokenHash: BigUInt
    public let value: BigUInt
    public let random: Data            // 16 bytes
    public let masterPublicKey: BigUInt

    /// Whether this was received (false) or sent by us (true).
    public let isSentNote: Bool

    /// Computed nullifier: poseidon([nullifyingKey, leafIndex]).
    /// Set after the wallet's nullifying key is known.
    public var nullifier: BigUInt?

    /// Whether this UTXO has been spent (nullifier seen on-chain).
    public var isSpent: Bool = false

    /// The commitment type (shield vs transact).
    public let commitmentType: CommitmentType
}

/// Aggregated balance for a single token.
public struct TokenScanBalance: Sendable {
    public let tokenHash: BigUInt
    public let totalValue: BigUInt
    public let spendableValue: BigUInt
    public let utxoCount: Int
}

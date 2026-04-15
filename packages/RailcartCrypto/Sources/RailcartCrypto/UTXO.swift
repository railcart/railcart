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
    public var masterPublicKey: BigUInt

    /// Whether this was received (false) or sent by us (true).
    public let isSentNote: Bool

    /// Computed nullifier: poseidon([nullifyingKey, leafIndex]).
    /// Set after the wallet's nullifying key is known.
    public var nullifier: BigUInt?

    /// Whether this UTXO has been spent (nullifier seen on-chain).
    public var isSpent: Bool = false

    /// The commitment type (shield vs transact).
    public let commitmentType: CommitmentType

    /// POI blinded commitment: `poseidon([hash, npk, globalTreePosition])`.
    /// Set by `Scanner` after the UTXO is created. Stable for the lifetime of
    /// the UTXO (doesn't depend on POI node state).
    public var blindedCommitment: String?

    /// Balance bucket derived from POI node response. Defaults to `.spendable`
    /// on non-POI chains; set to the real bucket after the POI node is queried.
    public var balanceBucket: WalletBalanceBucket = .spendable

    /// Whether this UTXO is a "change" output (sent to self). Used to
    /// distinguish `missingInternalPOI` vs `missingExternalPOI`.
    /// We approximate this with `isSentNote` since our native scanner doesn't
    /// track the SDK's explicit OutputType.
    public var isChange: Bool { isSentNote }
}

/// Aggregated balance for a single token.
public struct TokenScanBalance: Sendable {
    public let tokenHash: BigUInt
    public let totalValue: BigUInt
    public let spendableValue: BigUInt
    public let utxoCount: Int
}

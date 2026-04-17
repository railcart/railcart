import BigInt
import Foundation

/// Blinded commitments: POI-node identifiers for shield/transact/unshield events.
///
/// Matches `@railgun-community/engine`'s `BlindedCommitment` class. Results are
/// returned as 0x-prefixed lowercase hex strings, zero-padded to 64 chars (32 bytes).
public enum BlindedCommitment {
    public static let treeMaxItems = 65_536

    /// Global tree position as used by the POI node: `tree * TREE_MAX_ITEMS + index`.
    public static func globalTreePosition(tree: Int, index: Int) -> BigUInt {
        BigUInt(tree * treeMaxItems + index)
    }

    /// Compute the blinded commitment for a shield or transact commitment:
    /// `poseidon([commitmentHash, npk, globalTreePosition])`.
    public static func forShieldOrTransact(
        commitmentHash: BigUInt,
        npk: BigUInt,
        globalTreePosition: BigUInt
    ) -> String {
        Poseidon.hashHex([commitmentHash, npk, globalTreePosition])
    }

    /// Convenience for callers that have a UTXO's tree/index rather than the
    /// pre-computed global position.
    public static func forShieldOrTransact(
        commitmentHash: BigUInt,
        npk: BigUInt,
        tree: Int,
        index: Int
    ) -> String {
        forShieldOrTransact(
            commitmentHash: commitmentHash,
            npk: npk,
            globalTreePosition: globalTreePosition(tree: tree, index: index)
        )
    }

    /// Blinded commitment for an unshield event: the railgun txid normalized to
    /// a 0x-prefixed 32-byte hex string.
    public static func forUnshield(railgunTxid: String) -> String {
        let stripped = stripHexPrefix(railgunTxid).lowercased()
        let padded: String
        if stripped.count < 64 {
            padded = String(repeating: "0", count: 64 - stripped.count) + stripped
        } else if stripped.count > 64 {
            // Mirror ByteUtils.trim(side: 'left') — keep the rightmost 64 chars.
            padded = String(stripped.suffix(64))
        } else {
            padded = stripped
        }
        return "0x" + padded
    }

    /// Compute a note public key from a master public key and random:
    /// `poseidon([mpk, random])`. Same formula for shield and transact notes.
    public static func notePublicKey(masterPublicKey: BigUInt, random: BigUInt) -> BigUInt {
        Poseidon.hash([masterPublicKey, random])
    }

    /// Compute a note public key from a master public key and 16-byte random bytes.
    public static func notePublicKey(masterPublicKey: BigUInt, random: Data) -> BigUInt {
        notePublicKey(masterPublicKey: masterPublicKey, random: BigUInt(random))
    }

    private static func stripHexPrefix(_ s: String) -> String {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return String(s.dropFirst(2))
        }
        return s
    }
}

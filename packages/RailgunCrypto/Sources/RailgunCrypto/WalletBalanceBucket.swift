import Foundation

/// Which balance bucket a UTXO falls into, given its POI status and metadata.
///
/// Mirrors `WalletBalanceBucket` from `@railgun-community/engine`. Only
/// `.spendable` UTXOs may be selected for transactions on POI-enabled chains;
/// the other buckets should be surfaced to the user but not spent.
public enum WalletBalanceBucket: String, Sendable, Codable, CaseIterable {
    case spent = "Spent"
    case spendable = "Spendable"
    case shieldPending = "ShieldPending"
    case shieldBlocked = "ShieldBlocked"
    case proofSubmitted = "ProofSubmitted"
    case missingInternalPOI = "MissingInternalPOI"
    case missingExternalPOI = "MissingExternalPOI"
}

public enum POIStatusClassifier {
    /// Compute a UTXO's balance bucket from its POI node response.
    ///
    /// - Parameters:
    ///   - isSpent: UTXO's nullifier has been seen on-chain.
    ///   - isShieldCommitment: UTXO originated from a shield event (not a transact).
    ///   - isChange: UTXO is a change output from one of our own transactions.
    ///               Distinguishes MissingInternalPOI vs MissingExternalPOI.
    ///   - poisPerList: Response from `POINodeClient.poisPerList` for this
    ///                  UTXO's blinded commitment (nil = not yet queried).
    ///   - activeListKeys: The Active lists on the current chain. Defaults to
    ///                     the single default list key.
    ///
    /// Mirrors `POI.getBalanceBucket` in `@railgun-community/engine`.
    public static func bucket(
        isSpent: Bool,
        isShieldCommitment: Bool,
        isChange: Bool,
        poisPerList: [String: POIStatus]?,
        activeListKeys: [String] = [defaultPOIListKey]
    ) -> WalletBalanceBucket {
        if isSpent {
            return .spent
        }

        guard let pois = poisPerList, hasAllKeys(pois, activeListKeys) else {
            if isShieldCommitment { return .shieldPending }
            return isChange ? .missingInternalPOI : .missingExternalPOI
        }

        if hasValidPOIs(pois, listKeys: activeListKeys) {
            return .spendable
        }

        if activeListKeys.contains(where: { pois[$0] == .shieldBlocked }) {
            return .shieldBlocked
        }

        if isShieldCommitment {
            return .shieldPending
        }

        if activeListKeys.contains(where: { pois[$0] == .proofSubmitted }) {
            return .proofSubmitted
        }

        return isChange ? .missingInternalPOI : .missingExternalPOI
    }

    private static func hasAllKeys(_ pois: [String: POIStatus], _ keys: [String]) -> Bool {
        keys.allSatisfy { pois[$0] != nil }
    }

    private static func hasValidPOIs(_ pois: [String: POIStatus], listKeys: [String]) -> Bool {
        listKeys.allSatisfy { pois[$0] == .valid }
    }
}

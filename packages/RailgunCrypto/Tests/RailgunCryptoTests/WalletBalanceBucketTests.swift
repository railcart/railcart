import Testing
@testable import RailgunCrypto

/// Tests for `POIStatusClassifier.bucket` — mirrors the decision tree in
/// `@railgun-community/engine`'s `POI.getBalanceBucket`.
@Suite("Wallet Balance Bucket")
struct WalletBalanceBucketTests {
    private let listKey = "list1"

    @Test("spent UTXO is always .spent regardless of POI")
    func spentOverridesEverything() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: true,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: [listKey: .valid],
            activeListKeys: [listKey]
        )
        #expect(bucket == .spent)
    }

    @Test("no POI response on shield → .shieldPending")
    func noPOIResponseShieldPending() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: true,
            isChange: false,
            poisPerList: nil,
            activeListKeys: [listKey]
        )
        #expect(bucket == .shieldPending)
    }

    @Test("no POI response on transact change → .missingInternalPOI")
    func noPOIChange() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: true,
            poisPerList: nil,
            activeListKeys: [listKey]
        )
        #expect(bucket == .missingInternalPOI)
    }

    @Test("no POI response on transact external → .missingExternalPOI")
    func noPOIExternal() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: nil,
            activeListKeys: [listKey]
        )
        #expect(bucket == .missingExternalPOI)
    }

    @Test("response missing active list key falls through to missing*")
    func responseMissingListKey() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: ["some-other-list": .valid],
            activeListKeys: [listKey]
        )
        #expect(bucket == .missingExternalPOI)
    }

    @Test("all active lists Valid → .spendable")
    func allValidSpendable() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: [listKey: .valid],
            activeListKeys: [listKey]
        )
        #expect(bucket == .spendable)
    }

    @Test("ShieldBlocked on any active list → .shieldBlocked")
    func shieldBlocked() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: true,
            isChange: false,
            poisPerList: [listKey: .shieldBlocked],
            activeListKeys: [listKey]
        )
        #expect(bucket == .shieldBlocked)
    }

    @Test("shield with Missing status → .shieldPending (not missing external)")
    func shieldWithMissingIsPending() {
        // Freshly shielded: POI node knows nothing, but because this is a
        // shield commitment we report ShieldPending, not MissingExternalPOI.
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: true,
            isChange: false,
            poisPerList: [listKey: .missing],
            activeListKeys: [listKey]
        )
        #expect(bucket == .shieldPending)
    }

    @Test("transact with ProofSubmitted → .proofSubmitted")
    func proofSubmitted() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: [listKey: .proofSubmitted],
            activeListKeys: [listKey]
        )
        #expect(bucket == .proofSubmitted)
    }

    @Test("transact with Missing status → .missingExternalPOI or .missingInternalPOI")
    func transactMissing() {
        let external = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: [listKey: .missing],
            activeListKeys: [listKey]
        )
        #expect(external == .missingExternalPOI)

        let `internal` = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: true,
            poisPerList: [listKey: .missing],
            activeListKeys: [listKey]
        )
        #expect(`internal` == .missingInternalPOI)
    }

    @Test("multi-list: one Valid and one Missing still → not spendable")
    func multiListOnePartial() {
        let bucket = POIStatusClassifier.bucket(
            isSpent: false,
            isShieldCommitment: false,
            isChange: false,
            poisPerList: ["a": .valid, "b": .missing],
            activeListKeys: ["a", "b"]
        )
        #expect(bucket == .missingExternalPOI)
    }
}

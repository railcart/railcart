import Testing
import BigInt
import Foundation
@testable import RailcartCrypto

/// Test vectors generated from @railgun-community/engine WalletNode.
/// Mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
@Suite("RAILGUN Key Derivation")
struct KeyDerivationTests {
    static let testSeed = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"

    // MARK: - BIP32

    @Test("Master key from seed")
    func masterKey() {
        let master = RailgunKeyDerivation.getMasterKey(seed: Self.testSeed)
        #expect(master.chainKey == "1fafc64161d1807e294cc9fded180ca2009aaaedf4cbd7359d4aaa3bb462f411")
        #expect(master.chainCode == "30d550bc2f61a7c206a1eba3704502da77f366fe69721265b3b7e2c7f05eeabc")
    }

    @Test("Spending key derivation path m/44'/1984'/0'/0'/0'")
    func spendingPath() {
        let master = RailgunKeyDerivation.getMasterKey(seed: Self.testSeed)
        let spending = RailgunKeyDerivation.derivePath(master, segments: [44, 1984, 0, 0, 0])
        #expect(spending.chainKey == "08b2d974aa7fffd9d068b78c34434c534ddcd9343fcbf5aa12cf78e1a3c1ccb9")
    }

    @Test("Viewing key derivation path m/420'/1984'/0'/0'/0'")
    func viewingPath() {
        let master = RailgunKeyDerivation.getMasterKey(seed: Self.testSeed)
        let viewing = RailgunKeyDerivation.derivePath(master, segments: [420, 1984, 0, 0, 0])
        #expect(viewing.chainKey == "9a9e1ca3b9476dc8500b43f30f34104c92a3eedfd727757ffd0ad15da8e11572")
    }

    // MARK: - BLAKE-512

    @Test("BLAKE-512 of spending private key")
    func blake512SpendingKey() {
        let privKey = Data(hexString: "08b2d974aa7fffd9d068b78c34434c534ddcd9343fcbf5aa12cf78e1a3c1ccb9")!
        let hash = Blake512.hash(privKey)
        #expect(hash.prefix(32).hexString == "a111f4ff18943e9fca2813ba6af629367fe9873dc189fe8891214b7512a111e6")
    }

    @Test("BLAKE-512 of [1,2,3]")
    func blake512Simple() {
        let data = Data([1, 2, 3])
        let hash = Blake512.hash(data)
        // Reference from Node.js blake-hash
        #expect(hash.hexString == "bda8c64a899b28d384b33889989b377a959b45c948f061752925794a2458b83ae2ea72d91e1db52c560e851b9176086bd13bafb79088a14069d0a0a03ad294ad")
    }

    // MARK: - BabyJubJub

    @Test("Base8 point is on curve")
    func base8OnCurve() {
        #expect(BabyJubJub.isOnCurve(BabyJubJub.base8))
    }

    @Test("Generator point is on curve")
    func generatorOnCurve() {
        #expect(BabyJubJub.isOnCurve(BabyJubJub.generator))
    }

    @Test("Identity point is on curve")
    func identityOnCurve() {
        #expect(BabyJubJub.isOnCurve(BabyJubJub.identity))
    }

    @Test("Spending public key matches SDK")
    func spendingPublicKey() {
        let keys = RailgunKeyDerivation.deriveKeys(seed: Self.testSeed, index: 0)
        let expectedX = BigUInt("3008064177791584c9378d04a8f382f43195f76d3fd6f758a50076dcd392ae4c", radix: 16)!
        let expectedY = BigUInt("2834610a1ec9e739a664edc0c8eb0839065e2debfbc592d5e75e3c978bcc29a0", radix: 16)!
        #expect(keys.spendingPublicKey.x == expectedX)
        #expect(keys.spendingPublicKey.y == expectedY)
    }

    // MARK: - Viewing key (Ed25519)

    @Test("Viewing public key matches SDK")
    func viewingPublicKey() {
        let keys = RailgunKeyDerivation.deriveKeys(seed: Self.testSeed, index: 0)
        #expect(keys.viewingPublicKey.hexString == "df2dfb942aa6fb8cf9fe60d7984cd10b20b59027e677ecb4960d764f7d42408a")
    }

    // MARK: - Nullifying key

    @Test("Nullifying key matches SDK")
    func nullifyingKey() {
        let keys = RailgunKeyDerivation.deriveKeys(seed: Self.testSeed, index: 0)
        let expected = BigUInt("191c0148087eae6e205cdd0811e5c33581f0b8947907a3c2a11b9ec81220761d", radix: 16)!
        #expect(keys.nullifyingKey == expected)
    }

    // MARK: - Master public key

    @Test("Master public key matches SDK")
    func masterPublicKey() {
        let keys = RailgunKeyDerivation.deriveKeys(seed: Self.testSeed, index: 0)
        let expected = BigUInt("2ac7a8341580f1243d35c5e2ca8b87c6c3e2b569ded3c86a4f3381acdf09ff9d", radix: 16)!
        #expect(keys.masterPublicKey == expected)
    }
}

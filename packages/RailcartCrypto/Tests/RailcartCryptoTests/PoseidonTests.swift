import Testing
import BigInt
@testable import RailcartCrypto

/// Test vectors generated from @railgun-community/circomlibjs poseidon implementation.
@Suite("Poseidon Hash")
struct PoseidonTests {
    // MARK: - circomlibjs canonical test vectors

    @Test("poseidon([1, 2])")
    func twoInputs() {
        let result = Poseidon.hashHex([1, 2])
        #expect(result == "0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a")
    }

    @Test("poseidon([0, 0])")
    func twoZeros() {
        let result = Poseidon.hashHex([0, 0])
        #expect(result == "0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864")
    }

    @Test("poseidon([1])")
    func singleOne() {
        let result = Poseidon.hashHex([1])
        #expect(result == "0x29176100eaa962bdc1fe6c654d6a3c130e96a4d1168b33848b897dc502820133")
    }

    @Test("poseidon([0])")
    func singleZero() {
        let result = Poseidon.hashHex([0])
        #expect(result == "0x2a09a9fd93c590c26b91effbb2499f07e8f7aa12e2b4940a3aed2411cb65e11c")
    }

    @Test("poseidon([1, 2, 3])")
    func threeInputs() {
        let result = Poseidon.hashHex([1, 2, 3])
        #expect(result == "0x0e7732d89e6939c0ff03d5e58dab6302f3230e269dc5b968f725df34ab36d732")
    }

    @Test("poseidon([1, 2, 3, 4])")
    func fourInputs() {
        let result = Poseidon.hashHex([1, 2, 3, 4])
        #expect(result == "0x299c867db6c1fdd79dcefa40e4510b9837e60ebb1ce0663dbaa525df65250465")
    }

    // MARK: - RAILGUN merkle tree zero values

    @Test("RAILGUN merkle tree level 0 (MERKLE_ZERO_VALUE)")
    func merkleZeroValue() {
        // keccak256("Railgun") % SNARK_PRIME
        let zero = BigUInt("0488f89b25bc7011eaf6a5edce71aeafb9fe706faa3c0a5cd9cbe868ae3b9ffc", radix: 16)!
        let level1 = Poseidon.hash(zero, zero)
        let expected1 = BigUInt("01c405064436affeae1fc8e30b2e417b4243bbb819adca3b55bb32efc3e43a4f", radix: 16)!
        #expect(level1 == expected1)
    }

    @Test("RAILGUN merkle tree levels 1–4")
    func merkleTreeLevels() {
        let zero = BigUInt("0488f89b25bc7011eaf6a5edce71aeafb9fe706faa3c0a5cd9cbe868ae3b9ffc", radix: 16)!
        let expectedLevels = [
            "01c405064436affeae1fc8e30b2e417b4243bbb819adca3b55bb32efc3e43a4f",
            "0888d37652d10d1781db54b70af87b42a2916e87118f507218f9a42a58e85ed2",
            "183f531ead7217ebc316b4c02a2aad5ad87a1d56d4fb9ed81bf84f644549eaf5",
            "093c48f1ecedf2baec231f0af848a57a76c6cf05b290a396707972e1defd17df",
        ]

        var prev = zero
        for (i, expectedHex) in expectedLevels.enumerated() {
            prev = Poseidon.hash(prev, prev)
            let expected = BigUInt(expectedHex, radix: 16)!
            #expect(prev == expected, "Merkle level \(i + 1) mismatch")
        }
    }

    // MARK: - Field arithmetic

    @Test("BN254 field prime")
    func fieldPrime() {
        let p = BN254Field.prime
        #expect(p == BigUInt("21888242871839275222246405745257275088548364400416034343698204186575808495617"))
    }

    @Test("pow5 basic")
    func pow5() {
        let result = BN254Field.pow5(BigUInt(2))
        #expect(result == BigUInt(32))
    }

    @Test("pow5 wraps around field")
    func pow5Modular() {
        let large = BN254Field.prime - 1
        let result = BN254Field.pow5(large)
        // (p-1)^5 mod p = (-1)^5 mod p = p-1
        #expect(result == BN254Field.prime - 1)
    }
}

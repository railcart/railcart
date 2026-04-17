import Testing
import BigInt
import Foundation
@testable import RailgunCrypto

/// Test vectors generated from @railgun-community/engine's BlindedCommitment
/// class (see nodejs-project/node_modules/@railgun-community/engine/dist/poi/
/// blinded-commitment.js).
@Suite("Blinded Commitment")
struct BlindedCommitmentTests {
    // MARK: - Shield / Transact

    @Test("poseidon([1, 2, 3]) → simple integer inputs")
    func simpleIntegerInputs() {
        let result = BlindedCommitment.forShieldOrTransact(
            commitmentHash: 1,
            npk: 2,
            globalTreePosition: 3
        )
        #expect(result == "0x0e7732d89e6939c0ff03d5e58dab6302f3230e269dc5b968f725df34ab36d732")
    }

    @Test("realistic hash + npk, tree 0 index 5")
    func realisticTree0Index5() {
        let hash = BigUInt(
            "1e85ea4d8a71c5c8d4f9f9a8e6e4b2f1a1e5c9b3d0f8a6c4e2f7d5b1a9c8e6f4",
            radix: 16
        )!
        let npk = BigUInt("12345678901234567890123456789012345678", radix: 10)!
        let result = BlindedCommitment.forShieldOrTransact(
            commitmentHash: hash,
            npk: npk,
            tree: 0,
            index: 5
        )
        #expect(result == "0x2abbad9fc31e6d69074aa279e98e6ffd3fceb8cf89c3d6c884b6650a243e85c8")
    }

    @Test("tree 2 index 100 → global position 131172")
    func tree2Index100() {
        let pos = BlindedCommitment.globalTreePosition(tree: 2, index: 100)
        #expect(pos == 131_172)

        let result = BlindedCommitment.forShieldOrTransact(
            commitmentHash: 0xdeadbeef,
            npk: 999,
            globalTreePosition: pos
        )
        #expect(result == "0x09331042f5160617dbcb90423e7f204c23966982c2bd8d49c1b482a1607c34a2")
    }

    @Test("global tree position formula: tree * 65536 + index")
    func globalTreePositionFormula() {
        #expect(BlindedCommitment.globalTreePosition(tree: 0, index: 0) == 0)
        #expect(BlindedCommitment.globalTreePosition(tree: 0, index: 65_535) == 65_535)
        #expect(BlindedCommitment.globalTreePosition(tree: 1, index: 0) == 65_536)
        #expect(BlindedCommitment.globalTreePosition(tree: 3, index: 42) == 3 * 65_536 + 42)
    }

    // MARK: - Unshield

    @Test("unshield: short txid is zero-padded to 32 bytes")
    func unshieldShortPadded() {
        let result = BlindedCommitment.forUnshield(railgunTxid: "0xabc123")
        #expect(result == "0x0000000000000000000000000000000000000000000000000000000000abc123")
    }

    @Test("unshield: non-prefixed txid still padded and lowercased")
    func unshieldNoPrefix() {
        let result = BlindedCommitment.forUnshield(railgunTxid: "ABC123")
        #expect(result == "0x0000000000000000000000000000000000000000000000000000000000abc123")
    }

    @Test("unshield: 32-byte txid passes through unchanged (lowercased)")
    func unshieldFullLength() {
        let txid = "0x5e3d2b1a0c9e8f7d6c5b4a3928170605040302010f0e0d0c0b0a090807060504"
        let result = BlindedCommitment.forUnshield(railgunTxid: txid)
        #expect(result == txid)
    }

    // MARK: - Note public key

    @Test("npk = poseidon([mpk, random]) matches poseidon vector")
    func notePublicKeyMatchesPoseidon() {
        // For mpk=1, random=2 this is poseidon([1,2]) from the existing test vectors.
        let npk = BlindedCommitment.notePublicKey(masterPublicKey: 1, random: BigUInt(2))
        let expected = BigUInt(
            "115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a",
            radix: 16
        )!
        #expect(npk == expected)
    }

    @Test("npk from Data random: bytes are interpreted as big-endian")
    func notePublicKeyFromData() {
        let randomData = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                               0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
        let npk = BlindedCommitment.notePublicKey(masterPublicKey: 1, random: randomData)
        let expected = BlindedCommitment.notePublicKey(masterPublicKey: 1, random: BigUInt(2))
        #expect(npk == expected)
    }
}

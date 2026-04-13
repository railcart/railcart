import Testing
import BigInt
import Foundation
@testable import RailcartCrypto

@Suite("Proof Assembly")
struct ProofAssemblyTests {
    static let tokenHash = BigUInt(12345)

    static func makeUTXO(tree: Int = 0, position: Int, value: BigUInt, spent: Bool = false) -> UTXO {
        var utxo = UTXO(
            tree: tree,
            position: position,
            hash: Data(repeating: UInt8(position), count: 32),
            txid: Data(repeating: 0, count: 32),
            blockNumber: 100,
            tokenHash: tokenHash,
            value: value,
            random: Data(repeating: 0xCC, count: 16),
            masterPublicKey: BigUInt(999),
            isSentNote: false,
            nullifier: BigUInt(position * 1000),
            commitmentType: .transactCommitmentV2
        )
        utxo.isSpent = spent
        return utxo
    }

    // MARK: - UTXO Selection

    @Test("Select single UTXO covering amount")
    func selectSingleUTXO() throws {
        let utxos = [
            Self.makeUTXO(position: 0, value: 100),
            Self.makeUTXO(position: 1, value: 200),
            Self.makeUTXO(position: 2, value: 50),
        ]

        let selected = try ProofAssembler.selectUTXOs(
            from: utxos, tokenHash: Self.tokenHash, amount: 150
        )

        // Should select the 200-value UTXO (greedy: largest first)
        #expect(selected.count == 1)
        #expect(selected[0].value == 200)
    }

    @Test("Select multiple UTXOs to cover amount")
    func selectMultipleUTXOs() throws {
        let utxos = [
            Self.makeUTXO(position: 0, value: 100),
            Self.makeUTXO(position: 1, value: 80),
            Self.makeUTXO(position: 2, value: 50),
        ]

        let selected = try ProofAssembler.selectUTXOs(
            from: utxos, tokenHash: Self.tokenHash, amount: 170
        )

        // 100 + 80 = 180 >= 170
        #expect(selected.count == 2)
        let total = selected.reduce(BigUInt(0)) { $0 + $1.value }
        #expect(total >= 170)
    }

    @Test("Insufficient balance throws")
    func insufficientBalance() {
        let utxos = [Self.makeUTXO(position: 0, value: 50)]

        #expect(throws: ProofAssembler.Error.self) {
            try ProofAssembler.selectUTXOs(
                from: utxos, tokenHash: Self.tokenHash, amount: 100
            )
        }
    }

    @Test("Skips spent UTXOs")
    func skipsSpent() throws {
        let utxos = [
            Self.makeUTXO(position: 0, value: 200, spent: true),
            Self.makeUTXO(position: 1, value: 100),
        ]

        let selected = try ProofAssembler.selectUTXOs(
            from: utxos, tokenHash: Self.tokenHash, amount: 100
        )

        #expect(selected.count == 1)
        #expect(selected[0].value == 100)
    }

    @Test("No spendable UTXOs throws")
    func noSpendable() {
        let utxos = [Self.makeUTXO(position: 0, value: 200, spent: true)]

        #expect(throws: ProofAssembler.Error.self) {
            try ProofAssembler.selectUTXOs(
                from: utxos, tokenHash: Self.tokenHash, amount: 100
            )
        }
    }

    @Test("Skips wrong token")
    func skipsWrongToken() {
        let utxos = [Self.makeUTXO(position: 0, value: 200)]

        #expect(throws: ProofAssembler.Error.self) {
            try ProofAssembler.selectUTXOs(
                from: utxos, tokenHash: BigUInt(99999), amount: 100
            )
        }
    }

    // MARK: - Bridge JSON serialization

    @Test("ProofInputs serializes to bridge JSON")
    func bridgeJSON() {
        let inputs = ProofInputs(
            tokenHash: BigUInt(42),
            spendingPublicKey: (x: BigUInt(1), y: BigUInt(2)),
            nullifyingKey: BigUInt(3),
            inputs: [
                ProofInputs.InputUTXO(
                    random: BigUInt(100),
                    value: BigUInt(1000),
                    pathElements: [BigUInt](repeating: BigUInt(0), count: 16),
                    leafIndex: BigUInt(5)
                ),
            ],
            outputs: [
                ProofInputs.OutputNote(notePublicKey: BigUInt(10), value: BigUInt(800)),
                ProofInputs.OutputNote(notePublicKey: BigUInt(11), value: BigUInt(200)),
            ],
            merkleRoot: BigUInt(999),
            nullifiers: [BigUInt(555)],
            commitmentsOut: [BigUInt(777), BigUInt(888)]
        )

        let json = inputs.toBridgeJSON()

        // Verify key fields are present and hex-formatted
        let tokenAddr = json["tokenAddress"] as? String
        #expect(tokenAddr?.hasPrefix("0x") == true)
        #expect(tokenAddr?.count == 66) // 0x + 64 hex chars

        let pubKey = json["publicKey"] as? [String]
        #expect(pubKey?.count == 2)

        let randomIn = json["randomIn"] as? [String]
        #expect(randomIn?.count == 1)

        let npkOut = json["npkOut"] as? [String]
        #expect(npkOut?.count == 2)
    }
}

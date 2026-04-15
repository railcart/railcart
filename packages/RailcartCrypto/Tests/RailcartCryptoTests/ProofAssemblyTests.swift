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
            tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            amount: BigUInt(1000000),
            treeNumber: 0,
            merkleRoot: BigUInt(999),
            inputs: [
                ProofInputs.InputUTXO(
                    random: BigUInt(100),
                    value: BigUInt(1000000),
                    pathElements: [BigUInt](repeating: BigUInt(0), count: 16),
                    leafIndex: BigUInt(5),
                    commitmentHash: BigUInt(0)
                ),
            ]
        )

        let json = inputs.toBridgeJSON()

        let tokenAddr = json["tokenAddress"] as? String
        #expect(tokenAddr == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")

        let amount = json["amount"] as? String
        #expect(amount == "1000000")

        let treeNumber = json["treeNumber"] as? Int
        #expect(treeNumber == 0)

        let merkleRoot = json["merkleRoot"] as? String
        #expect(merkleRoot?.hasPrefix("0x") == true)

        let utxos = json["utxos"] as? [[String: Any]]
        #expect(utxos?.count == 1)
        let utxo = utxos?[0]
        #expect((utxo?["leafIndex"] as? Int) == 5)

        let pathElements = utxo?["pathElements"] as? [String]
        #expect(pathElements?.count == 16)
    }
}

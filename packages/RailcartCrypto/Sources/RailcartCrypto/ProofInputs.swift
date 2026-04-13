import BigInt
import Foundation

/// Assembled proof inputs ready for the groth16 prover.
/// Maps to the RAILGUN engine's PrivateInputsRailgun + PublicInputsRailgun.
public struct ProofInputs: Sendable {
    /// The token being spent (as a Poseidon hash of token data).
    public let tokenHash: BigUInt
    /// Spending public key [x, y] on BabyJubJub.
    public let spendingPublicKey: (x: BigUInt, y: BigUInt)
    /// Nullifying key.
    public let nullifyingKey: BigUInt

    /// Per-input UTXO data (one entry per UTXO being spent).
    public let inputs: [InputUTXO]
    /// Per-output note data (recipient + change notes).
    public let outputs: [OutputNote]

    /// Merkle root of the spending tree.
    public let merkleRoot: BigUInt
    /// Nullifiers for each input UTXO.
    public let nullifiers: [BigUInt]
    /// Commitment hashes for each output note.
    public let commitmentsOut: [BigUInt]

    /// Data for a single input UTXO.
    public struct InputUTXO: Sendable {
        public let random: BigUInt
        public let value: BigUInt
        public let pathElements: [BigUInt]  // 16 sibling hashes
        public let leafIndex: BigUInt
    }

    /// Data for a single output note.
    public struct OutputNote: Sendable {
        public let notePublicKey: BigUInt
        public let value: BigUInt
    }
}

/// Selects UTXOs and assembles proof inputs for a spend.
public enum ProofAssembler {
    /// Error types for proof assembly.
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case insufficientBalance(have: BigUInt, need: BigUInt)
        case noSpendableUTXOs
        case merkleProofUnavailable(tree: Int, position: Int)

        public var errorDescription: String? {
            switch self {
            case .insufficientBalance(let have, let need):
                "Insufficient balance: have \(have), need \(need)"
            case .noSpendableUTXOs:
                "No spendable UTXOs available"
            case .merkleProofUnavailable(let tree, let position):
                "Merkle proof unavailable for tree \(tree) position \(position)"
            }
        }
    }

    /// Select UTXOs and build proof inputs for an unshield of `amount` of `tokenHash`.
    ///
    /// - Parameters:
    ///   - scanner: The scanner with populated UTXOs and merkle trees.
    ///   - keys: The wallet's key set.
    ///   - tokenHash: The Poseidon hash of the token to spend.
    ///   - amount: The amount to unshield (in token's smallest unit).
    ///   - recipientNPK: Note public key for the recipient (for unshield, derived from recipient address).
    ///   - changeNPK: Note public key for the change output (derived from our wallet).
    public static func assembleUnshield(
        scanner: Scanner,
        keys: RailgunKeyDerivation.KeySet,
        tokenHash: BigUInt,
        amount: BigUInt,
        recipientNPK: BigUInt,
        changeNPK: BigUInt
    ) throws -> ProofInputs {
        // Select UTXOs
        let selected = try selectUTXOs(
            from: scanner.utxos,
            tokenHash: tokenHash,
            amount: amount
        )

        let totalIn = selected.reduce(BigUInt(0)) { $0 + $1.value }
        let change = totalIn - amount

        // All selected UTXOs must be in the same tree
        guard let tree = selected.first?.tree else {
            throw Error.noSpendableUTXOs
        }

        // Build input data with merkle proofs
        var inputUTXOs = [ProofInputs.InputUTXO]()
        var nullifiers = [BigUInt]()

        for utxo in selected {
            guard let proof = scanner.merkleProof(for: utxo) else {
                throw Error.merkleProofUnavailable(tree: utxo.tree, position: utxo.position)
            }

            inputUTXOs.append(ProofInputs.InputUTXO(
                random: BigUInt(utxo.random),
                value: utxo.value,
                pathElements: proof.elements,
                leafIndex: BigUInt(utxo.position)
            ))

            let nullifier = Poseidon.hash([keys.nullifyingKey, BigUInt(utxo.position)])
            nullifiers.append(nullifier)
        }

        // Build outputs
        var outputs = [ProofInputs.OutputNote]()

        // Recipient output
        let recipientCommitment = Poseidon.hash([recipientNPK, tokenHash, amount])
        outputs.append(ProofInputs.OutputNote(
            notePublicKey: recipientNPK,
            value: amount
        ))

        // Change output (if any)
        var commitmentsOut = [recipientCommitment]
        if change > 0 {
            let changeCommitment = Poseidon.hash([changeNPK, tokenHash, change])
            outputs.append(ProofInputs.OutputNote(
                notePublicKey: changeNPK,
                value: change
            ))
            commitmentsOut.append(changeCommitment)
        }

        // Merkle root from the spending tree
        let merkleRoot = scanner.merkleRoot(forTree: tree)

        return ProofInputs(
            tokenHash: tokenHash,
            spendingPublicKey: keys.spendingPublicKey,
            nullifyingKey: keys.nullifyingKey,
            inputs: inputUTXOs,
            outputs: outputs,
            merkleRoot: merkleRoot,
            nullifiers: nullifiers,
            commitmentsOut: commitmentsOut
        )
    }

    /// Select UTXOs to cover `amount` for a given token.
    /// Uses a simple greedy approach: sort by value descending, take until covered.
    static func selectUTXOs(
        from utxos: [UTXO],
        tokenHash: BigUInt,
        amount: BigUInt
    ) throws -> [UTXO] {
        let spendable = utxos
            .filter { $0.tokenHash == tokenHash && !$0.isSpent && !$0.isSentNote && $0.value > 0 }
            .sorted { $0.value > $1.value }

        guard !spendable.isEmpty else { throw Error.noSpendableUTXOs }

        var selected = [UTXO]()
        var total = BigUInt(0)

        for utxo in spendable {
            selected.append(utxo)
            total += utxo.value
            if total >= amount { break }
        }

        guard total >= amount else {
            throw Error.insufficientBalance(have: total, need: amount)
        }

        return selected
    }
}

// MARK: - Scanner extension for proof assembly

extension Scanner {
    /// Get the merkle root for a specific tree. Triggers lazy tree build if needed.
    public func merkleRoot(forTree tree: Int) -> BigUInt {
        buildTreesIfNeeded()
        return treeRoot(forTree: tree)
    }
}

// MARK: - JSON Serialization for Bridge Transport

extension ProofInputs {
    /// Serialize to a dictionary suitable for JSON transport to the Node.js bridge.
    /// All BigUInt values are converted to hex strings.
    public func toBridgeJSON() -> [String: Any] {
        [
            "tokenAddress": hexStr(tokenHash),
            "publicKey": [hexStr(spendingPublicKey.x), hexStr(spendingPublicKey.y)],
            "nullifyingKey": hexStr(nullifyingKey),
            "randomIn": inputs.map { hexStr($0.random) },
            "valueIn": inputs.map { hexStr($0.value) },
            "pathElements": inputs.map { $0.pathElements.map { hexStr($0) } },
            "leavesIndices": inputs.map { hexStr($0.leafIndex) },
            "npkOut": outputs.map { hexStr($0.notePublicKey) },
            "valueOut": outputs.map { hexStr($0.value) },
            "merkleRoot": hexStr(merkleRoot),
            "nullifiers": nullifiers.map { hexStr($0) },
            "commitmentsOut": commitmentsOut.map { hexStr($0) },
        ]
    }

    private func hexStr(_ value: BigUInt) -> String {
        "0x" + String(value, radix: 16).paddedLeft(toLength: 64, with: "0")
    }
}

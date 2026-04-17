import BigInt
import Foundation

/// Assembled proof inputs ready for the groth16 prover.
/// Maps to the RAILGUN engine's PrivateInputsRailgun + PublicInputsRailgun.
public struct ProofInputs: Sendable {
    /// The token address (ERC20 contract address, NOT a hash).
    public let tokenAddress: String
    /// Amount to unshield.
    public let amount: BigUInt
    /// Which merkle tree the UTXOs are in.
    public let treeNumber: Int
    /// Merkle root of the spending tree.
    public let merkleRoot: BigUInt

    /// Per-input UTXO data (one entry per UTXO being spent).
    public let inputs: [InputUTXO]

    /// Data for a single input UTXO.
    public struct InputUTXO: Sendable {
        public let random: BigUInt
        public let value: BigUInt
        public let pathElements: [BigUInt]  // 16 sibling hashes
        public let leafIndex: BigUInt
        public let commitmentHash: BigUInt  // The actual merkle leaf hash from subgraph
    }

}

/// Selects UTXOs and assembles proof inputs for a spend.
public enum ProofAssembler {
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

    /// Select UTXOs and build proof inputs for an unshield.
    ///
    /// The bridge method handles output notes, encryption, and signing.
    /// We just provide selected UTXOs with merkle proofs.
    ///
    /// - Parameter poiActive: When true (POI-enabled chains), only UTXOs with
    ///   `balanceBucket == .spendable` are considered. When false, every
    ///   non-spent UTXO is eligible (pre-POI behavior).
    public static func assembleUnshield(
        scanner: Scanner,
        tokenAddress: String,
        amount: BigUInt,
        poiActive: Bool = false
    ) throws -> ProofInputs {
        // Token hash for ERC20 is the address as a BigUInt (zero-padded to 32 bytes)
        let addrHex = tokenAddress.lowercased().hasPrefix("0x")
            ? String(tokenAddress.lowercased().dropFirst(2))
            : tokenAddress.lowercased()
        let tokenHash = BigUInt(addrHex, radix: 16) ?? 0

        let selected = try selectUTXOs(
            from: scanner.utxos,
            tokenHash: tokenHash,
            amount: amount,
            poiActive: poiActive
        )

        guard let tree = selected.first?.tree else {
            throw Error.noSpendableUTXOs
        }

        // Build the tree lazily (needed for merkle proofs)
        scanner.buildTreesIfNeeded()

        var inputUTXOs = [ProofInputs.InputUTXO]()
        for utxo in selected {
            guard let proof = scanner.merkleProof(for: utxo) else {
                throw Error.merkleProofUnavailable(tree: utxo.tree, position: utxo.position)
            }
            inputUTXOs.append(ProofInputs.InputUTXO(
                random: BigUInt(utxo.random),
                value: utxo.value,
                pathElements: proof.elements,
                leafIndex: BigUInt(utxo.position),
                commitmentHash: BigUInt(utxo.hash)
            ))
        }

        let merkleRoot = scanner.treeRoot(forTree: tree)

        return ProofInputs(
            tokenAddress: tokenAddress,
            amount: amount,
            treeNumber: tree,
            merkleRoot: merkleRoot,
            inputs: inputUTXOs
        )
    }

    /// Select UTXOs to cover `amount` for a given token.
    ///
    /// - Parameter poiActive: When true, only `.spendable` UTXOs are eligible;
    ///   UTXOs in any other bucket (ShieldPending, ShieldBlocked, Missing*POI)
    ///   are filtered out. Use for POI-enabled chains like Ethereum mainnet.
    public static func selectUTXOs(
        from utxos: [UTXO],
        tokenHash: BigUInt,
        amount: BigUInt,
        poiActive: Bool = false
    ) throws -> [UTXO] {
        let spendable = utxos
            .filter { utxo in
                utxo.tokenHash == tokenHash
                    && !utxo.isSpent
                    && !utxo.isSentNote
                    && utxo.value > 0
                    && (!poiActive || utxo.balanceBucket == .spendable)
            }
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
    /// Serialize to the format expected by `generateUnshieldProofNative` bridge method.
    public func toBridgeJSON() -> [String: Any] {
        [
            "tokenAddress": tokenAddress,
            "amount": String(amount),
            "treeNumber": treeNumber,
            "merkleRoot": hexStr(merkleRoot),
            "utxos": inputs.map { utxo in
                [
                    "value": hexStr(utxo.value),
                    "random": hexStr(utxo.random),
                    "leafIndex": Int(utxo.leafIndex),
                    "pathElements": utxo.pathElements.map { hexStr($0) },
                    "commitmentHash": hexStr(utxo.commitmentHash),
                ] as [String: Any]
            },
        ]
    }

    private func hexStr(_ value: BigUInt) -> String {
        "0x" + String(value, radix: 16).paddedLeft(toLength: 64, with: "0")
    }
}

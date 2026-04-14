import BigInt
import Foundation

/// Scans RAILGUN events and builds the local UTXO set for a wallet.
///
/// Ties together: QuickSync → Note Decryption → Merkle Tree → Balance Tracking.
public final class Scanner: @unchecked Sendable {
    /// Precomputed ECDH scalar from the viewing key (avoids re-deriving per commitment).
    private let preparedKey: RailgunECDH.PreparedKey
    /// The wallet's viewing private key (for shield note decryption).
    private let viewingPrivateKey: Data
    /// The wallet's nullifying key (for computing nullifiers).
    private let nullifyingKey: BigUInt
    /// The wallet's master public key (for ownership verification).
    private let masterPublicKey: BigUInt

    /// Merkle trees (indexed by tree number). Built lazily when proofs are needed.
    private var trees: [Int: PoseidonMerkleTree] = [:]
    /// Pending leaves to insert into trees, keyed by tree number.
    /// Sorted by position. Built into the tree on demand.
    private var pendingLeaves: [Int: [(position: Int, hash: Data)]] = [:]
    /// Whether trees have been built from pending leaves.
    private var treesBuilt = false
    /// All decrypted UTXOs owned by this wallet.
    private(set) public var utxos: [UTXO] = []
    /// Known nullifiers from the chain (for marking UTXOs as spent).
    private var knownNullifiers: Set<BigUInt> = []
    /// Last scanned block number.
    private(set) public var lastScannedBlock: Int = 0

    /// Progress callback: (processedCommitments, totalCommitments).
    public var onProgress: (@Sendable (Int, Int) -> Void)?

    public init(keys: RailgunKeyDerivation.KeySet) {
        self.preparedKey = RailgunECDH.prepareKey(viewingPrivateKey: keys.viewingPrivateKey)!
        self.viewingPrivateKey = keys.viewingPrivateKey
        self.nullifyingKey = keys.nullifyingKey
        self.masterPublicKey = keys.masterPublicKey
    }

    /// Scan events from the quick-sync subgraph for a chain.
    ///
    /// Fetches all events since `lastScannedBlock`, decrypts commitments,
    /// and updates balances. Merkle tree is built lazily when proofs are needed.
    public func scan(chainName: String) async throws {
        let qs = try QuickSync(chainName: chainName)
        let events = try await qs.fetchEvents(startBlock: lastScannedBlock)

        // Process nullifiers first (so we can mark UTXOs as spent)
        for nullifier in events.nullifiers {
            knownNullifiers.insert(BigUInt(nullifier.nullifier))
        }

        // Store commitment hashes for deferred merkle tree building.
        // Tree construction uses Poseidon which is expensive — defer until
        // a merkle proof is actually needed (i.e. proof generation).
        for commitment in events.commitments {
            let (tree, position, hash) = commitmentTreeInfo(commitment)
            storePendingLeaf(tree: tree, position: position, hash: hash)
        }

        // Decrypt commitments to find owned UTXOs
        let total = events.commitments.count
        var processed = 0

        for commitment in events.commitments {
            switch commitment {
            case .transact(let tc):
                processTransact(tc)
            case .shield(let sc):
                processShield(sc)
            case .opaque:
                break // Can't decrypt but hash is already in pendingLeaves for the merkle tree
            }

            processed += 1
            if processed % 500 == 0 {
                onProgress?(processed, total)
            }
        }

        // Mark spent UTXOs
        markSpentUTXOs()

        // Update last scanned block
        if let maxBlock = events.commitments.map({ commitmentBlock($0) }).max() {
            lastScannedBlock = max(lastScannedBlock, maxBlock)
        }
        if let maxNullBlock = events.nullifiers.map(\.blockNumber).max() {
            lastScannedBlock = max(lastScannedBlock, maxNullBlock)
        }

        onProgress?(total, total)
    }

    // MARK: - Balances

    /// Get aggregated balances per token hash.
    public var balances: [TokenScanBalance] {
        let grouped = Dictionary(grouping: utxos.filter { !$0.isSpent && !$0.isSentNote }) { $0.tokenHash }
        return grouped.map { (tokenHash, utxos) in
            let total = utxos.reduce(BigUInt(0)) { $0 + $1.value }
            return TokenScanBalance(
                tokenHash: tokenHash,
                totalValue: total,
                spendableValue: total,
                utxoCount: utxos.count
            )
        }
    }

    /// Get a merkle proof for a UTXO. Builds the tree lazily if needed.
    public func merkleProof(for utxo: UTXO) -> MerkleProof? {
        buildTreesIfNeeded()
        guard let tree = trees[utxo.tree] else { return nil }
        guard utxo.position < tree.count else { return nil }
        return tree.merkleProof(index: utxo.position)
    }

    // MARK: - Processing

    private func processTransact(_ tc: TransactCommitment) {
        guard let note = NoteDecryptor.decryptV2(
            ciphertext: tc.ciphertext,
            preparedKey: preparedKey
        ) else {
            return // Not our commitment
        }

        let nullifier = Poseidon.hash([nullifyingKey, BigUInt(tc.utxoIndex)])

        var utxo = UTXO(
            tree: tc.utxoTree,
            position: tc.utxoIndex,
            hash: tc.hash,
            txid: tc.txid,
            blockNumber: tc.blockNumber,
            tokenHash: note.tokenHash,
            value: note.value,
            random: note.random,
            masterPublicKey: note.masterPublicKey,
            isSentNote: note.isSentNote,
            nullifier: nullifier,
            commitmentType: .transactCommitmentV2
        )

        if knownNullifiers.contains(nullifier) {
            utxo.isSpent = true
        }

        utxos.append(utxo)
    }

    private func processShield(_ sc: ShieldCommitment) {
        // For shield commitments, the preimage data is public (npk, token, value).
        // We need to check if the npk belongs to our wallet by trying to decrypt
        // the random from the encrypted bundle.
        guard let sharedKey = RailgunECDH.sharedKeyFast(
            preparedKey: preparedKey,
            blindedPublicKey: sc.shieldKey
        ) else {
            return // Not our commitment
        }

        // Decrypt the random from encryptedBundle
        guard sc.encryptedBundle.count >= 2 else { return }
        let bundle0 = sc.encryptedBundle[0]
        let bundle1 = sc.encryptedBundle[1]
        guard bundle0.count == 32, bundle1.count >= 16 else { return }

        // encryptedBundle[0] = IV (16 bytes) + TAG (16 bytes)
        // encryptedBundle[1] = encrypted random (first 16 bytes)
        let iv = Data(bundle0.prefix(16))
        let tag = Data(bundle0.suffix(16))
        let encryptedRandom = Data(bundle1.prefix(16))

        guard let decrypted = NoteDecryptor.aesGCMDecrypt(
            key: sharedKey,
            iv: iv,
            tag: tag,
            data: [encryptedRandom]
        ), let random = decrypted.first else {
            return
        }

        // ERC20 token hash is just the address zero-padded to 32 bytes (as BigUInt)
        let addrHex = sc.preImage.tokenAddress.lowercased().hasPrefix("0x")
            ? String(sc.preImage.tokenAddress.lowercased().dropFirst(2))
            : sc.preImage.tokenAddress.lowercased()
        let tokenHash = BigUInt(addrHex, radix: 16) ?? 0

        let nullifier = Poseidon.hash([nullifyingKey, BigUInt(sc.utxoIndex)])

        var utxo = UTXO(
            tree: sc.utxoTree,
            position: sc.utxoIndex,
            hash: sc.hash,
            txid: sc.txid,
            blockNumber: sc.blockNumber,
            tokenHash: tokenHash,
            value: sc.preImage.value,
            random: random,
            masterPublicKey: masterPublicKey,
            isSentNote: false,
            nullifier: nullifier,
            commitmentType: .shieldCommitment
        )

        if knownNullifiers.contains(nullifier) {
            utxo.isSpent = true
        }

        utxos.append(utxo)
    }

    private func markSpentUTXOs() {
        for i in utxos.indices {
            if let nullifier = utxos[i].nullifier, knownNullifiers.contains(nullifier) {
                utxos[i].isSpent = true
            }
        }
    }

    // MARK: - Merkle Tree Management (Deferred)

    private func storePendingLeaf(tree: Int, position: Int, hash: Data) {
        if pendingLeaves[tree] == nil {
            pendingLeaves[tree] = []
        }
        pendingLeaves[tree]!.append((position: position, hash: hash))
        treesBuilt = false
    }

    /// Progress callback for tree building: (insertedLeaves, totalLeaves).
    public var onTreeBuildProgress: (@Sendable (Int, Int) -> Void)?

    /// Build merkle trees from all pending leaves. Called lazily before proof generation.
    /// This is expensive (Poseidon hashing) so it's deferred from the scan phase.
    func buildTreesIfNeeded() {
        guard !treesBuilt else { return }

        let totalLeaves = pendingLeaves.values.reduce(0) { $0 + $1.count }
        var insertedSoFar = 0

        let chunkSize = 500

        // Remap any leaves with position >= maxLeaves to the correct tree
        // (subgraph sometimes reports boundary leaves in the wrong tree).
        var remapped = [Int: [(position: Int, hash: Data)]]()
        for (treeNumber, leaves) in pendingLeaves {
            for leaf in leaves {
                let actualTree = treeNumber + leaf.position / PoseidonMerkleTree.maxLeaves
                let actualPos = leaf.position % PoseidonMerkleTree.maxLeaves
                remapped[actualTree, default: []].append((position: actualPos, hash: leaf.hash))
            }
        }

        for (treeNumber, leaves) in remapped {
            var tree = trees[treeNumber] ?? PoseidonMerkleTree()
            let sorted = leaves.sorted { $0.position < $1.position }

            // Build full batch with gap-filling, then insert in chunks
            var fullBatch = [BigUInt]()
            var nextExpected = tree.count
            for leaf in sorted {
                guard leaf.position >= nextExpected else { continue }
                while nextExpected < leaf.position {
                    fullBatch.append(PoseidonMerkleTree.zeros[0])
                    nextExpected += 1
                }
                fullBatch.append(BigUInt(leaf.hash))
                nextExpected += 1
            }

            // Insert in chunks for progress reporting while keeping batch efficiency
            var offset = 0
            while offset < fullBatch.count {
                let end = min(offset + chunkSize, fullBatch.count)
                let chunk = Array(fullBatch[offset..<end])
                tree.insertLeaves(chunk)
                insertedSoFar += chunk.count
                onTreeBuildProgress?(insertedSoFar, totalLeaves)
                offset = end
            }
            trees[treeNumber] = tree
        }

        onTreeBuildProgress?(totalLeaves, totalLeaves)
        // Keep pendingLeaves — they're needed for persistence so the tree can
        // be rebuilt after app restart. The dedup logic (nextExpected >= tree.count)
        // ensures they won't be re-inserted into an already-built tree.
        treesBuilt = true
    }

    /// Get tree root without triggering a build (for internal use after build).
    func treeRoot(forTree tree: Int) -> BigUInt {
        trees[tree]?.root ?? PoseidonMerkleTree.zeros[PoseidonMerkleTree.depth]
    }

    // MARK: - Persistence Accessors

    /// Expose known nullifiers for serialization.
    var knownNullifiersList: Set<BigUInt> { knownNullifiers }

    /// Expose pending leaves for serialization.
    var pendingLeavesList: [Int: [(position: Int, hash: Data)]] { pendingLeaves }

    /// Restore state from a previous session.
    func restoreState(
        lastScannedBlock: Int,
        utxos: [UTXO],
        nullifiers: Set<BigUInt>,
        pendingLeaves: [Int: [(position: Int, hash: Data)]]
    ) {
        self.lastScannedBlock = lastScannedBlock
        self.utxos = utxos
        self.knownNullifiers = nullifiers
        self.pendingLeaves = pendingLeaves
        self.treesBuilt = false
    }

    private func commitmentTreeInfo(_ commitment: ScanCommitment) -> (tree: Int, position: Int, hash: Data) {
        let (tree, position, hash): (Int, Int, Data) = switch commitment {
        case .transact(let tc): (tc.utxoTree, tc.utxoIndex, tc.hash)
        case .shield(let sc): (sc.utxoTree, sc.utxoIndex, sc.hash)
        case .opaque(let hash, let tree, let index, _): (tree, index, hash)
        }
        // The subgraph occasionally reports position 65536 in tree N, which is
        // actually tree N+1 position 0 on-chain. Remap to match the contract.
        if position >= PoseidonMerkleTree.maxLeaves {
            return (tree + position / PoseidonMerkleTree.maxLeaves,
                    position % PoseidonMerkleTree.maxLeaves, hash)
        }
        return (tree, position, hash)
    }

    private func commitmentBlock(_ commitment: ScanCommitment) -> Int {
        switch commitment {
        case .transact(let tc): return tc.blockNumber
        case .shield(let sc): return sc.blockNumber
        case .opaque(_, _, _, let blockNumber): return blockNumber
        }
    }
}

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
    /// Tracks which (tree, position) pairs are already in `utxos` so that
    /// re-scans (which re-fetch the boundary block) don't create duplicates.
    private var utxoKeys: Set<String> = []
    /// Known nullifiers from the chain (for marking UTXOs as spent).
    private var knownNullifiers: Set<BigUInt> = []
    /// Maps every nullifier to the Ethereum txid that emitted it. Used to
    /// derive a "tx X spent our UTXO Y which was created by tx Z" dependency
    /// graph for debugging. Backwards-compatible on load: older state files
    /// don't contain this map and we fall through to the bigint set above.
    private var nullifierTxids: [BigUInt: Data] = [:]
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
            let value = BigUInt(nullifier.nullifier)
            knownNullifiers.insert(value)
            nullifierTxids[value] = nullifier.txid
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
    /// `totalValue` sums all non-spent received notes; `spendableValue` only
    /// sums `.spendable` UTXOs. On non-POI chains the two are equal because
    /// every UTXO defaults to `.spendable`.
    public var balances: [TokenScanBalance] {
        let grouped = Dictionary(grouping: utxos.filter { !$0.isSpent && !$0.isSentNote }) { $0.tokenHash }
        return grouped.map { (tokenHash, utxos) in
            let total = utxos.reduce(BigUInt(0)) { $0 + $1.value }
            let spendable = utxos
                .filter { $0.balanceBucket == .spendable }
                .reduce(BigUInt(0)) { $0 + $1.value }
            return TokenScanBalance(
                tokenHash: tokenHash,
                totalValue: total,
                spendableValue: spendable,
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

        // The SDK XOR-encodes the receiver's mpk in the ciphertext for self-
        // sends and hidden-sender transfers. For a received note, the true
        // receiver mpk is our own, regardless of what's in the decrypted
        // bytes. Using the decrypted value directly yields wrong npks (and
        // therefore wrong blinded commitments) for self-change notes where
        // encodedMPK = ourMPK ^ ourMPK = 0.
        //
        // For sent notes (fee to broadcaster) the decrypted value happens
        // to be the receiver's mpk when senderRandom is non-null (common
        // broadcaster path), so we keep it as-is.
        let effectiveReceiverMPK = note.isSentNote ? note.masterPublicKey : masterPublicKey

        var utxo = UTXO(
            tree: tc.utxoTree,
            position: tc.utxoIndex,
            hash: tc.hash,
            txid: tc.txid,
            blockNumber: tc.blockNumber,
            tokenHash: note.tokenHash,
            value: note.value,
            random: note.random,
            masterPublicKey: effectiveReceiverMPK,
            isSentNote: note.isSentNote,
            nullifier: nullifier,
            commitmentType: .transactCommitmentV2
        )
        utxo.blindedCommitment = Self.computeBlindedCommitment(
            hash: tc.hash,
            masterPublicKey: effectiveReceiverMPK,
            random: note.random,
            tree: tc.utxoTree,
            index: tc.utxoIndex
        )

        if knownNullifiers.contains(nullifier) {
            utxo.isSpent = true
        }

        appendUTXO(utxo)
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
        utxo.blindedCommitment = Self.computeBlindedCommitment(
            hash: sc.hash,
            masterPublicKey: masterPublicKey,
            random: random,
            tree: sc.utxoTree,
            index: sc.utxoIndex
        )

        if knownNullifiers.contains(nullifier) {
            utxo.isSpent = true
        }

        appendUTXO(utxo)
    }

    /// Append a UTXO to `utxos`, rejecting duplicates by (tree, position).
    /// Incremental scans re-fetch the boundary block, so the same commitment
    /// can show up again after it's already been processed — without this
    /// dedupe, balances would compound and the debug view would show repeats.
    private func appendUTXO(_ utxo: UTXO) {
        let key = "\(utxo.tree):\(utxo.position)"
        if utxoKeys.contains(key) { return }
        utxoKeys.insert(key)
        utxos.append(utxo)
    }

    /// Compute the POI blinded commitment for a UTXO.
    /// Done at scan time so it survives persistence and POI query batching.
    private static func computeBlindedCommitment(
        hash: Data,
        masterPublicKey: BigUInt,
        random: Data,
        tree: Int,
        index: Int
    ) -> String {
        let npk = BlindedCommitment.notePublicKey(
            masterPublicKey: masterPublicKey,
            random: random
        )
        return BlindedCommitment.forShieldOrTransact(
            commitmentHash: BigUInt(hash),
            npk: npk,
            tree: tree,
            index: index
        )
    }

    // MARK: - POI Integration

    /// Force every UTXO into `.spendable`. Use on chains where POI isn't
    /// active — ensures non-POI chains never display bucket states and that
    /// any persisted bucket data from prior buggy scans self-heals.
    public func resetAllBucketsToSpendable() {
        for i in utxos.indices where utxos[i].balanceBucket != .spendable {
            utxos[i].balanceBucket = .spendable
        }
    }

    /// Backfill blinded commitments on any UTXO missing one. Use after loading
    /// old persisted state that predates the blinded-commitment field.
    public func backfillBlindedCommitments() {
        for i in utxos.indices where utxos[i].blindedCommitment == nil {
            utxos[i].blindedCommitment = Self.computeBlindedCommitment(
                hash: utxos[i].hash,
                masterPublicKey: utxos[i].masterPublicKey,
                random: utxos[i].random,
                tree: utxos[i].tree,
                index: utxos[i].position
            )
        }
    }

    /// Apply a POI node response to update per-UTXO balance buckets.
    ///
    /// - Parameter poisPerList: Map from blinded commitment to per-list status
    ///     (as returned by `POINodeClient.poisPerList`). UTXOs with a blinded
    ///     commitment not present in the map are treated as having no POI
    ///     response (falls through to `ShieldPending` / `MissingExternal*POI`
    ///     in the classifier).
    /// - Parameter activeListKeys: Active POI lists on this chain.
    public func applyPOIStatuses(
        poisPerList: [String: [String: POIStatus]],
        activeListKeys: [String] = [defaultPOIListKey]
    ) {
        for i in utxos.indices {
            let commitmentType = utxos[i].commitmentType
            let isShield = commitmentType == .shieldCommitment
                || commitmentType == .legacyGeneratedCommitment
            let perList = utxos[i].blindedCommitment.flatMap { poisPerList[$0] }
            utxos[i].balanceBucket = POIStatusClassifier.bucket(
                isSpent: utxos[i].isSpent,
                isShieldCommitment: isShield,
                isChange: utxos[i].isChange,
                poisPerList: perList,
                activeListKeys: activeListKeys
            )
        }
    }

    // MARK: - Debug dump

    /// A record of one transaction that's relevant to this wallet — either it
    /// created commitments we own, or it consumed nullifiers for UTXOs we
    /// own. Used to render a dependency view for debugging POI state.
    public struct DebugTx: Sendable {
        /// Ethereum txid (lowercase hex, no `0x`).
        public let txid: String
        /// UTXOs this tx created that are ours.
        public let createdUTXOs: [UTXO]
        /// UTXOs of ours this tx consumed (we saw our nullifier emitted by
        /// this txid).
        public let spentUTXOs: [UTXO]
        /// Parent txs — the txids that created the UTXOs this tx consumed.
        /// If parents are present, this tx's POI depends on those being Valid.
        public let parentTxids: [String]
        /// Earliest block across created/spent commitments. Used for ordering.
        public let blockNumber: Int
    }

    /// Build a per-tx debug view of everything the scanner knows about this
    /// wallet's involvement in transactions. Each tx appears at most once,
    /// with its created and spent UTXOs and the set of parent txs it depends
    /// on. Output is sorted newest-first by block.
    public func debugTransactions() -> [DebugTx] {
        struct Mutable {
            var created: [UTXO] = []
            var spent: [UTXO] = []
            var block: Int = 0
        }
        var byTxid: [String: Mutable] = [:]

        func key(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        // Every owned UTXO contributes to the tx that created it.
        for utxo in utxos {
            let created = key(utxo.txid)
            byTxid[created, default: Mutable()].created.append(utxo)
            if byTxid[created]!.block == 0 { byTxid[created]!.block = utxo.blockNumber }
            byTxid[created]!.block = max(byTxid[created]!.block, utxo.blockNumber)

            // If we spent this UTXO, also attribute it to the consuming tx.
            if utxo.isSpent,
               let nullifier = utxo.nullifier,
               let spenderData = nullifierTxids[nullifier] {
                let spent = key(spenderData)
                byTxid[spent, default: Mutable()].spent.append(utxo)
            }
        }

        // Compile final tx records with parent linkage.
        return byTxid.map { txid, m in
            let parents = Set(m.spent.map { key($0.txid) })
                .subtracting([txid])
                .sorted()
            return DebugTx(
                txid: txid,
                createdUTXOs: m.created,
                spentUTXOs: m.spent,
                parentTxids: parents,
                blockNumber: m.block
            )
        }
        .sorted { $0.blockNumber > $1.blockNumber }
    }

    /// A single "pending POI" entry for the UI — one per (txid, tokenHash).
    /// Aggregates all non-spent, non-sent, non-spendable owned UTXOs.
    public struct PendingPOIEntry: Sendable, Hashable {
        public let txid: String                     // lowercase hex, no 0x
        public let tokenHash: BigUInt
        public let totalValue: BigUInt
        public let bucket: WalletBalanceBucket      // worst bucket across the group
        public let isShield: Bool
        public let blockNumber: Int                 // earliest block of grouped UTXOs
    }

    /// All owned UTXOs that aren't yet spendable, grouped by (txid, tokenHash).
    ///
    /// Surfaces the full "why isn't my money spendable?" set to the UI,
    /// including imported/legacy wallet UTXOs that have no matching local
    /// `Transaction` record.
    public func pendingPOIEntries() -> [PendingPOIEntry] {
        let pending = utxos.filter { utxo in
            !utxo.isSpent && !utxo.isSentNote && utxo.balanceBucket != .spendable
        }
        struct Key: Hashable { let txid: Data; let tokenHash: BigUInt }
        let grouped = Dictionary(grouping: pending) { Key(txid: $0.txid, tokenHash: $0.tokenHash) }

        return grouped.map { key, group in
            let hex = key.txid.map { String(format: "%02x", $0) }.joined()
            let total = group.reduce(BigUInt(0)) { $0 + $1.value }
            let bucket = Self.worstBucket(group.map(\.balanceBucket))
            let firstType = group.first?.commitmentType
            let isShield = firstType == .shieldCommitment || firstType == .legacyGeneratedCommitment
            let minBlock = group.map(\.blockNumber).min() ?? 0
            return PendingPOIEntry(
                txid: hex,
                tokenHash: key.tokenHash,
                totalValue: total,
                bucket: bucket,
                isShield: isShield,
                blockNumber: minBlock
            )
        }
        .sorted { $0.blockNumber > $1.blockNumber }
    }

    /// Ranks buckets so UI can surface the most alarming state when a single
    /// transaction has UTXOs in different buckets.
    private static func worstBucket(_ buckets: [WalletBalanceBucket]) -> WalletBalanceBucket {
        func rank(_ b: WalletBalanceBucket) -> Int {
            switch b {
            case .shieldBlocked: 5
            case .missingExternalPOI: 4
            case .missingInternalPOI: 3
            case .shieldPending: 2
            case .proofSubmitted: 1
            case .spendable, .spent: 0
            }
        }
        return buckets.max(by: { rank($0) < rank($1) }) ?? .spendable
    }

    /// Per-shield-transaction POI status for this wallet.
    ///
    /// - `known`: txids for which this wallet has observed at least one shield
    ///   commitment (the scanner has caught up past that tx).
    /// - `pending`: subset of `known` where at least one owned, non-spent UTXO
    ///   is not yet `.spendable` — i.e. the POI node hasn't cleared it.
    ///
    /// txid strings are lowercase hex with no `0x` prefix, for cheap comparison
    /// with `Transaction.txHash` after normalization.
    public func shieldTxHashStatus() -> (known: Set<String>, pending: Set<String>) {
        var known: Set<String> = []
        var pending: Set<String> = []
        for utxo in utxos where utxo.commitmentType == .shieldCommitment {
            let hex = utxo.txid.map { String(format: "%02x", $0) }.joined()
            known.insert(hex)
            if !utxo.isSpent && utxo.balanceBucket != .spendable {
                pending.insert(hex)
            }
        }
        return (known, pending)
    }

    /// Collect all blinded commitments for non-spent UTXOs, suitable for
    /// passing to `POINodeClient.poisPerList`.
    public func pendingPOIQueries() -> [BlindedCommitmentQuery] {
        utxos.compactMap { utxo in
            guard !utxo.isSpent, let bc = utxo.blindedCommitment else { return nil }
            let type: BlindedCommitmentType = switch utxo.commitmentType {
            case .shieldCommitment, .legacyGeneratedCommitment: .shield
            case .transactCommitmentV2, .legacyEncryptedCommitment: .transact
            }
            return BlindedCommitmentQuery(blindedCommitment: bc, type: type)
        }
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

    /// Expose nullifier → spending txid map for serialization.
    var nullifierTxidsList: [BigUInt: Data] { nullifierTxids }

    /// Restore state from a previous session.
    func restoreState(
        lastScannedBlock: Int,
        utxos: [UTXO],
        nullifiers: Set<BigUInt>,
        pendingLeaves: [Int: [(position: Int, hash: Data)]],
        nullifierTxids: [BigUInt: Data] = [:]
    ) {
        self.lastScannedBlock = lastScannedBlock
        // Dedupe by (tree, position) so existing saved state with duplicates
        // from before the appendUTXO guard heals itself on load.
        var seen: Set<String> = []
        var unique: [UTXO] = []
        for utxo in utxos {
            let key = "\(utxo.tree):\(utxo.position)"
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(utxo)
        }
        self.utxos = unique
        self.utxoKeys = seen
        self.knownNullifiers = nullifiers
        self.pendingLeaves = pendingLeaves
        self.nullifierTxids = nullifierTxids
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

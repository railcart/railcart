import Foundation
import Observation
import RailgunCrypto
import BigInt
import CryptoKit
import CommonCrypto

/// Detailed scan progress information from the native scanner.
struct NativeScanProgress: Sendable {
    enum Phase: Sendable {
        case initializingKeys
        case fetchingEvents
        case decryptingCommitments(processed: Int, total: Int)
        case buildingMerkleTree
        case computingBalances
        case complete
    }

    let phase: Phase
    let progress: Double
    let status: String
}

/// Native RAILGUN scanner that replaces the Node.js SDK scanning.
/// Heavy crypto work runs on background threads; only progress updates touch @MainActor.
@MainActor
@Observable
final class NativeScannerService {
    /// Per-wallet-chain scanners keyed by "walletID:chainName".
    private var scanners: [String: RailgunCrypto.Scanner] = [:]
    /// Cached key sets keyed by walletID (keys are chain-independent).
    private var keySets: [String: RailgunKeyDerivation.KeySet] = [:]
    /// Creation block numbers per wallet, for skipping pre-creation history.
    private var creationBlocks: [String: [String: Int]] = [:]

    private(set) var scanProgress: NativeScanProgress?
    private(set) var isScanning = false

    /// POI query state per chain. Driven both by the scan pipeline and by
    /// user-initiated retries from the middle section.
    private(set) var poiStatus: [String: POIFetchStatus] = [:]

    /// Initialize keys for a wallet from its mnemonic.
    /// Does the expensive key derivation + state loading on a background thread.
    func initializeWallet(walletID: String, mnemonic: String, derivationIndex: Int, creationBlockNumbers: [String: Int]? = nil) async {
        if keySets[walletID] != nil { return }

        updateProgress(.initializingKeys, progress: 0, status: "Deriving wallet keys...")

        let keys = await Task.detached(priority: .userInitiated) {
            let seed = Self.bip39Seed(mnemonic: mnemonic)
            return RailgunKeyDerivation.deriveKeys(seed: seed, index: derivationIndex)
        }.value

        keySets[walletID] = keys
        if let blocks = creationBlockNumbers {
            creationBlocks[walletID] = blocks
        }
    }

    /// Scan private balances for all wallets on a chain.
    ///
    /// - Parameter poiNodeURLs: If non-empty, after the scan completes the
    ///   scanner queries the POI aggregator and tags each UTXO with a
    ///   `WalletBalanceBucket`. Pass `[]` to skip POI (e.g. non-POI chains).
    func scanAllWallets(chainName: String, walletIDs: [String], poiNodeURLs: [URL] = []) async {
        isScanning = true
        resetProgress()

        // Phase 1: Load scanners (quick — just JSON from disk)
        updateProgress(.initializingKeys, progress: 0, status: "Loading wallet state...")

        let isPOIActive = Chain(rawValue: chainName)?.isPOIActive == true

        for walletID in walletIDs {
            guard let keys = keySets[walletID] else { continue }
            let scannerKey = "\(walletID):\(chainName)"
            if scanners[scannerKey] == nil {
                let stateURL = Self.scannerStateURL(walletID: walletID, chainName: chainName)
                let scanner = await Task.detached(priority: .userInitiated) {
                    let s = RailgunCrypto.Scanner(keys: keys)
                    // load() handles missing-state and legacy migration internally.
                    try? s.load(from: stateURL)
                    return s
                }.value
                if scanner.lastScannedBlock > 0 {
                    AppLogger.shared.log("native-scan", "Restored \(chainName) state for \(walletID.prefix(8))... (block \(scanner.lastScannedBlock), \(scanner.utxos.count) UTXOs)")
                }
                scanners[scannerKey] = scanner
            }
            // Non-POI chains must never display bucket states. Heal any
            // persisted bucket data left over from a prior buggy scan.
            if !isPOIActive {
                scanners[scannerKey]?.resetAllBucketsToSpendable()
            }
        }

        do {
            let startBlock = walletIDs.compactMap { walletID -> Int? in
                let scannerKey = "\(walletID):\(chainName)"
                if let scanner = scanners[scannerKey], scanner.lastScannedBlock > 0 {
                    return scanner.lastScannedBlock
                }
                return creationBlocks[walletID]?[chainName]
            }.min() ?? 0

            // Phase 2: Fetch events from subgraph (network I/O)
            // Track pages fetched so progress moves smoothly during multi-page fetches
            let fetchStartStatus = startBlock > 0
                ? "Fetching events from block \(startBlock)..."
                : "Fetching events..."
            updateProgress(.fetchingEvents, progress: 0.02, status: fetchStartStatus)

            var qs = try QuickSync(chainName: chainName)

            // Track per-type fetch counts so parallel fetches don't bounce the progress
            let fetchCounts = FetchCounts()
            qs.onFetchProgress = { @Sendable [weak self, fetchCounts] (count, type) in
                fetchCounts.update(type: type, count: count)
                Task { @MainActor [weak self, fetchCounts] in
                    let total = fetchCounts.total
                    // Small increments: 1% per 20k items, never exceed 30%
                    // We'll jump to 35% when fetching actually completes
                    let fetchProgress = min(0.02 + Double(total) / 20_000.0 * 0.01, 0.30)
                    let summary = fetchCounts.summary
                    self?.updateProgress(.fetchingEvents, progress: fetchProgress,
                                         status: "Fetching: \(summary)")
                }
            }
            let events = try await qs.fetchEvents(startBlock: startBlock)

            let totalCommitments = events.commitments.count
            let totalNullifiers = events.nullifiers.count

            if totalCommitments == 0 && totalNullifiers == 0 {
                updateProgress(.complete, progress: 1.0, status: "Up to date")
            } else {
                // Phase 3: Read commitments (CPU-bound, most of the time)
                // This phase gets 0.35 – 0.92 of the progress bar
                let decryptStart = 0.35
                let decryptEnd = 0.92

                updateProgress(
                    .decryptingCommitments(processed: 0, total: totalCommitments),
                    progress: decryptStart,
                    status: "Reading \(totalCommitments) commitments..."
                )

                for walletID in walletIDs {
                    let scannerKey = "\(walletID):\(chainName)"
                    guard let scanner = scanners[scannerKey] else { continue }

                    scanner.onProgress = { @Sendable [weak self] (processed: Int, total: Int) in
                        Task { @MainActor [weak self] in
                            let pct = Double(processed) / Double(max(total, 1))
                            let progress = decryptStart + pct * (decryptEnd - decryptStart)
                            self?.updateProgress(
                                .decryptingCommitments(processed: processed, total: total),
                                progress: progress,
                                status: "Reading commitments: \(processed) / \(total)"
                            )
                        }
                    }

                    try await Task.detached(priority: .userInitiated) {
                        try await scanner.scan(chainName: chainName)
                    }.value
                }

                // Phase 4: POI status (optional — skipped if no URLs provided)
                if !poiNodeURLs.isEmpty {
                    updateProgress(.computingBalances, progress: 0.93, status: "Checking POI status...")
                    await queryPOIStatuses(chainName: chainName, walletIDs: walletIDs, poiNodeURLs: poiNodeURLs)
                }

                // Phase 5: Save state
                updateProgress(.computingBalances, progress: 0.97, status: "Saving scan state...")

                for walletID in walletIDs {
                    let scannerKey = "\(walletID):\(chainName)"
                    guard let scanner = scanners[scannerKey] else { continue }
                    let stateURL = Self.scannerStateURL(walletID: walletID, chainName: chainName)
                    await Task.detached(priority: .utility) {
                        try? scanner.save(to: stateURL)
                    }.value
                }

                // Count owned UTXOs for the final status
                let ownedCount = walletIDs.reduce(0) { total, walletID in
                    total + (scanners["\(walletID):\(chainName)"]?.utxos.count ?? 0)
                }

                updateProgress(.complete, progress: 1.0,
                               status: "Found \(ownedCount) notes in \(totalCommitments) commitments")
            }
        } catch {
            AppLogger.shared.log("native-scan", "Scan failed: \(error.localizedDescription)")
            updateProgress(.complete, progress: 1.0,
                           status: "Scan failed: \(error.localizedDescription)")
        }

        isScanning = false
    }

    /// Get spendable private balances for a wallet on a chain.
    ///
    /// Only returns the `.spendable` subset — UTXOs in ShieldPending,
    /// ShieldBlocked, Missing*POI, or ProofSubmitted buckets are excluded so
    /// the UI never offers the user funds they can't actually spend. On
    /// non-POI chains this matches the total, since every UTXO defaults to
    /// `.spendable`.
    func getPrivateBalances(chainName: String, walletID: String) -> [TokenBalance] {
        let scannerKey = "\(walletID):\(chainName)"
        guard let scanner = scanners[scannerKey] else { return [] }

        return scanner.balances.compactMap { balance -> TokenBalance? in
            guard let token = resolveTokenAddress(tokenHash: balance.tokenHash, chainName: chainName) else {
                return nil
            }
            return TokenBalance(tokenAddress: token, amount: String(balance.spendableValue))
        }
    }

    /// A pending-POI entry surfaced to the UI's middle section. One per
    /// (txid, tokenHash) for any owned UTXO that isn't yet spendable —
    /// including received transacts and UTXOs from imported/legacy wallets
    /// that have no matching local Transaction record.
    struct PendingPOI: Sendable, Identifiable {
        /// `"chainName:txid:tokenHash"` for stable SwiftUI identity.
        let id: String
        let txid: String                     // lowercase hex, no 0x
        let bucket: WalletBalanceBucket
        let isShield: Bool
        /// Resolved token metadata when known; nil for unknown tokens.
        let token: Token?
        /// Token address as hex if resolvable, else the raw token hash hex.
        let tokenDisplay: String
        /// Raw value in token's smallest unit (wei-equivalent).
        let amountRaw: String
        let blockNumber: Int
    }

    // MARK: - Debug

    /// Debug-only summary of one tx's relevance to this wallet.
    struct DebugTransaction: Sendable, Identifiable {
        var id: String { "\(chainName):\(walletID):\(txid)" }
        let chainName: String
        let walletID: String
        let txid: String                // lowercase hex, no 0x
        let blockNumber: Int
        /// Our UTXOs this tx created.
        let createdUTXOs: [DebugUTXO]
        /// Our UTXOs this tx consumed (their nullifier appeared in this tx).
        let spentUTXOs: [DebugUTXO]
        /// Txids that created UTXOs this tx consumed — its POI dependencies.
        let parentTxids: [String]
    }

    /// Debug-only UTXO rendering (token-resolved + bucket).
    struct DebugUTXO: Sendable, Identifiable {
        let id: String                  // "tree:position"
        let tokenDisplay: String        // address hex or ERC-20 symbol
        let amountRaw: String
        let bucket: WalletBalanceBucket
        let commitmentType: String
        let blindedCommitment: String?
        let isSpent: Bool
        let isSentNote: Bool
    }

    /// Produce a per-tx debug dump for a wallet on a chain.
    func debugTransactions(chainName: String, walletID: String) -> [DebugTransaction] {
        let scannerKey = "\(walletID):\(chainName)"
        guard let scanner = scanners[scannerKey] else { return [] }

        return scanner.debugTransactions().map { dt in
            DebugTransaction(
                chainName: chainName,
                walletID: walletID,
                txid: dt.txid,
                blockNumber: dt.blockNumber,
                createdUTXOs: dt.createdUTXOs.map { debugUTXO(from: $0, chainName: chainName) },
                spentUTXOs: dt.spentUTXOs.map { debugUTXO(from: $0, chainName: chainName) },
                parentTxids: dt.parentTxids
            )
        }
    }

    private func debugUTXO(from utxo: UTXO, chainName: String) -> DebugUTXO {
        let tokenDisplay: String
        if let addr = resolveTokenAddress(tokenHash: utxo.tokenHash, chainName: chainName),
           let chain = Chain(rawValue: chainName),
           let symbol = Token.supported.first(where: {
               $0.address(on: chain)?.lowercased() == addr.lowercased()
           })?.symbol {
            tokenDisplay = symbol
        } else {
            let hex = String(utxo.tokenHash, radix: 16)
            tokenDisplay = "0x" + String(repeating: "0", count: max(0, 40 - hex.count)) + hex
        }
        return DebugUTXO(
            id: "\(utxo.tree):\(utxo.position)",
            tokenDisplay: tokenDisplay,
            amountRaw: String(utxo.value),
            bucket: utxo.balanceBucket,
            commitmentType: utxo.commitmentType.rawValue,
            blindedCommitment: utxo.blindedCommitment,
            isSpent: utxo.isSpent,
            isSentNote: utxo.isSentNote
        )
    }

    /// Demo-only override for `pendingPOIEntries`. Keyed by "walletID:chainName".
    /// Live code never writes here; only `seedPendingPOIEntries` does.
    private var pendingPOISeed: [String: [PendingPOI]] = [:]

    /// Seed pending POI entries for demo/screenshot mode.
    func seedPendingPOIEntries(chainName: String, walletID: String, entries: [PendingPOI]) {
        pendingPOISeed["\(walletID):\(chainName)"] = entries
    }

    /// Seed POI fetch status for demo/screenshot mode.
    func seedPOIStatus(chainName: String, _ status: POIFetchStatus) {
        poiStatus[chainName] = status
    }

    /// All owned UTXOs that aren't yet spendable, grouped by (txid, tokenHash).
    func pendingPOIEntries(chainName: String, walletID: String) -> [PendingPOI] {
        let scannerKey = "\(walletID):\(chainName)"
        if let seeded = pendingPOISeed[scannerKey] { return seeded }
        guard let scanner = scanners[scannerKey] else { return [] }

        return scanner.pendingPOIEntries().map { entry in
            let resolvedAddress = resolveTokenAddress(tokenHash: entry.tokenHash, chainName: chainName)
            let token = resolvedAddress.flatMap { addr in
                Token.supported.first {
                    $0.address(on: Chain(rawValue: chainName) ?? .ethereum)?.lowercased() == addr.lowercased()
                }
            }
            let tokenHashHex = String(entry.tokenHash, radix: 16)
            let padded = String(repeating: "0", count: max(0, 40 - tokenHashHex.count)) + tokenHashHex
            let tokenDisplay = resolvedAddress ?? "0x" + padded
            return PendingPOI(
                id: "\(chainName):\(entry.txid):\(String(entry.tokenHash, radix: 16))",
                txid: entry.txid,
                bucket: entry.bucket,
                isShield: entry.isShield,
                token: token,
                tokenDisplay: tokenDisplay,
                amountRaw: String(entry.totalValue),
                blockNumber: entry.blockNumber
            )
        }
    }

    /// Per-shield-transaction POI status. Used by the pending-shield UI to
    /// show tx rows only while their UTXOs aren't yet spendable.
    struct ShieldTxStatus: Sendable {
        /// Txids (lowercase hex, no `0x`) the scanner has observed at least
        /// one shield commitment for.
        let known: Set<String>
        /// Subset of `known` with at least one not-yet-spendable UTXO.
        let pending: Set<String>
    }

    func shieldTxStatus(chainName: String, walletID: String) -> ShieldTxStatus {
        let scannerKey = "\(walletID):\(chainName)"
        guard let scanner = scanners[scannerKey] else {
            return ShieldTxStatus(known: [], pending: [])
        }
        let (known, pending) = scanner.shieldTxHashStatus()
        return ShieldTxStatus(known: known, pending: pending)
    }

    func isInitialized(walletID: String) -> Bool {
        keySets[walletID] != nil
    }

    /// Access the scanner for a wallet+chain (for proof assembly).
    func getScanner(walletID: String, chainName: String) -> RailgunCrypto.Scanner? {
        scanners["\(walletID):\(chainName)"]
    }

    /// Access the key set for a wallet (for proof assembly).
    func getKeySet(walletID: String) -> RailgunKeyDerivation.KeySet? {
        keySets[walletID]
    }

    /// Clear saved scan state and in-memory scanners, forcing a full rescan from block 0.
    func clearSavedState(walletIDs: [String], chainName: String) {
        for walletID in walletIDs {
            let scannerKey = "\(walletID):\(chainName)"
            scanners.removeValue(forKey: scannerKey)
            let url = Self.scannerStateURL(walletID: walletID, chainName: chainName)
            try? FileManager.default.removeItem(at: url)
            // Also clean up the legacy single-file format if it's still around.
            let legacyURL = url.deletingPathExtension().appendingPathExtension("json")
            try? FileManager.default.removeItem(at: legacyURL)
        }
        AppLogger.shared.log("native-scan", "Cleared scan state for \(chainName), will rescan from block 0")
    }

    // MARK: - POI

    /// Observable lifecycle of a POI node query.
    enum POIFetchStatus: Sendable, Equatable {
        case idle
        case querying
        case succeeded(at: Date)
        case failed(message: String, at: Date)
    }

    /// Observable lifecycle of POI proof generation + submission.
    /// Driven by the `generatePOIProofs` flow and the `poiProofProgress`
    /// stream coming from the Node.js SDK.
    enum POIProofGenStatus: Sendable, Equatable {
        case idle
        case running(progress: Double, message: String)
        case succeeded(at: Date)
        case failed(message: String, at: Date)
    }

    private(set) var poiProofGen: [String: POIProofGenStatus] = [:]

    /// Snapshot of blinded commitments that were in a Missing* bucket at the
    /// moment the user initiated a successful submission. Used to detect
    /// when NEW Missing commitments have arrived since the last submit —
    /// once that happens, `effectivePOIProofGen` reports `.idle` so the
    /// Submit button comes back.
    private struct POIProofSubmission: Codable, Sendable {
        let at: Date
        let submittedBlindedCommitments: [String]
    }
    private var poiProofSubmissions: [String: POIProofSubmission] = [:]

    /// Window during which a persisted `.succeeded` submission is considered
    /// still relevant. Beyond this the aggregator should have processed the
    /// proofs (or we should stop gating on a stale success).
    private static let submissionPersistWindow: TimeInterval = 2 * 60 * 60

    /// UserDefaults key for the last successful POI submission on `chainName`.
    /// Keyed per-chain; stores the JSON-encoded `POIProofSubmission`.
    private static func submissionKey(_ chainName: String) -> String {
        "railcart.poi.submission.\(chainName)"
    }

    /// Legacy key — a raw `Double` timestamp from the pre-snapshot format.
    /// Cleaned up on first load so it doesn't linger.
    private static func legacySubmissionKey(_ chainName: String) -> String {
        "railcart.poi.lastSubmit.\(chainName)"
    }

    /// Restore any persisted submission so the Submit button stays hidden
    /// across app restarts while proofs clear. Call once per service lifetime.
    func restorePersistedPOIProofState() {
        let defaults = RailcartDefaults.store
        let now = Date()
        for chain in Chain.allCases where chain.isPOIActive {
            // Clean up legacy timestamp-only key so the new-format data is
            // the single source of truth.
            defaults.removeObject(forKey: Self.legacySubmissionKey(chain.rawValue))

            let key = Self.submissionKey(chain.rawValue)
            guard let data = defaults.data(forKey: key),
                  let submission = try? JSONDecoder().decode(POIProofSubmission.self, from: data) else {
                continue
            }
            if now.timeIntervalSince(submission.at) < Self.submissionPersistWindow {
                poiProofGen[chain.rawValue] = .succeeded(at: submission.at)
                poiProofSubmissions[chain.rawValue] = submission
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Record progress from a `poiProofProgress` event. Called by
    /// BalanceService; intentionally lenient about unknown fields.
    func applyPOIProofProgress(chainName: String, progress: Double?, status: String?, message: String?) {
        let text = message ?? status ?? ""
        poiProofGen[chainName] = .running(progress: progress ?? 0, message: text)
    }

    func setPOIProofGen(chainName: String, _ newValue: POIProofGenStatus) {
        setPOIProofGen(chainName: chainName, newValue, submittedBlindedCommitments: nil)
    }

    /// Update proof-gen state. When transitioning to `.succeeded`, callers
    /// pass the set of blinded commitments that were in a Missing* bucket
    /// when submission started — we snapshot it so we can reopen the Submit
    /// button later if *new* Missing commitments arrive.
    func setPOIProofGen(
        chainName: String,
        _ newValue: POIProofGenStatus,
        submittedBlindedCommitments: Set<String>?
    ) {
        poiProofGen[chainName] = newValue
        let key = Self.submissionKey(chainName)
        if case .succeeded(let at) = newValue {
            let submission = POIProofSubmission(
                at: at,
                submittedBlindedCommitments: Array(submittedBlindedCommitments ?? [])
            )
            poiProofSubmissions[chainName] = submission
            if let data = try? JSONEncoder().encode(submission) {
                RailcartDefaults.store.set(data, forKey: key)
            }
        } else if case .idle = newValue {
            RailcartDefaults.store.removeObject(forKey: key)
            poiProofSubmissions.removeValue(forKey: chainName)
        }
    }

    /// Blinded commitments for every currently-Missing UTXO owned by any of
    /// the given wallets. Used both to snapshot at submit time and to detect
    /// drift after submit.
    func missingPOIBlindedCommitments(chainName: String, walletIDs: [String]) -> Set<String> {
        var result: Set<String> = []
        for walletID in walletIDs {
            guard let scanner = scanners["\(walletID):\(chainName)"] else { continue }
            for utxo in scanner.utxos {
                guard !utxo.isSpent, !utxo.isSentNote else { continue }
                guard utxo.balanceBucket == .missingInternalPOI
                    || utxo.balanceBucket == .missingExternalPOI else { continue }
                if let bc = utxo.blindedCommitment {
                    result.insert(bc)
                }
            }
        }
        return result
    }

    /// Effective proof-gen state for UI gating. When the raw state is
    /// `.succeeded` but new Missing commitments have appeared since the
    /// snapshot, returns `.idle` so the Submit button comes back.
    func effectivePOIProofGen(chainName: String, walletIDs: [String]) -> POIProofGenStatus {
        let raw = poiProofGen[chainName] ?? .idle
        guard case .succeeded = raw else { return raw }
        guard let submission = poiProofSubmissions[chainName] else { return raw }

        let current = missingPOIBlindedCommitments(chainName: chainName, walletIDs: walletIDs)
        let submitted = Set(submission.submittedBlindedCommitments)
        if !current.isSubset(of: submitted) {
            return .idle
        }
        return raw
    }

    /// User-initiated standalone POI refresh. Skips the scan pipeline — only
    /// re-queries the POI node for the UTXOs already indexed by the scanner
    /// and reapplies bucket statuses. Cheap and safe to call repeatedly.
    func refreshPOIStatuses(chainName: String, walletIDs: [String], poiNodeURLs: [URL]) async {
        await queryPOIStatuses(chainName: chainName, walletIDs: walletIDs, poiNodeURLs: poiNodeURLs)
    }

    /// Query the POI aggregator for every UTXO on this chain and apply the
    /// resulting balance buckets. Updates `poiStatus[chainName]` through the
    /// lifecycle. Drives both the scan's final phase and user-initiated
    /// retries.
    private func queryPOIStatuses(chainName: String, walletIDs: [String], poiNodeURLs: [URL]) async {
        guard let chain = Chain(rawValue: chainName) else { return }
        let poiChain = POIChain(type: 0, id: chain.chainId)

        poiStatus[chainName] = .querying

        // Backfill blinded commitments on any UTXO restored from pre-POI state.
        for walletID in walletIDs {
            guard let scanner = scanners["\(walletID):\(chainName)"] else { continue }
            scanner.backfillBlindedCommitments()
        }

        // Collect unique (blindedCommitment, type) queries across all wallets.
        var queryMap: [String: BlindedCommitmentQuery] = [:]
        for walletID in walletIDs {
            guard let scanner = scanners["\(walletID):\(chainName)"] else { continue }
            for query in scanner.pendingPOIQueries() {
                queryMap[query.blindedCommitment] = query
            }
        }
        guard !queryMap.isEmpty else {
            // No UTXOs to check — treat as a trivially successful refresh.
            poiStatus[chainName] = .succeeded(at: Date())
            return
        }
        let allQueries = Array(queryMap.values)

        let client = POINodeClient(nodeURLs: poiNodeURLs)
        // SDK caps batch size at 1000 in some call sites; match that.
        let batchSize = 1000
        var combined: [String: [String: POIStatus]] = [:]

        do {
            for start in stride(from: 0, to: allQueries.count, by: batchSize) {
                let batch = Array(allQueries[start..<min(start + batchSize, allQueries.count)])
                let response = try await client.poisPerList(
                    chain: poiChain,
                    listKeys: [defaultPOIListKey],
                    queries: batch
                )
                combined.merge(response) { $1 }
            }
        } catch {
            AppLogger.shared.log("native-scan", "POI query failed: \(error.localizedDescription)")
            poiStatus[chainName] = .failed(message: error.localizedDescription, at: Date())
            return
        }

        for walletID in walletIDs {
            guard let scanner = scanners["\(walletID):\(chainName)"] else { continue }
            scanner.applyPOIStatuses(poisPerList: combined)
        }

        poiStatus[chainName] = .succeeded(at: Date())
    }

    // MARK: - Private

    /// Thread-safe counter for parallel fetch progress.
    private final class FetchCounts: Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var counts: [String: Int] = [:]

        func update(type: String, count: Int) {
            lock.lock()
            counts[type] = count
            lock.unlock()
        }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            return counts.sorted(by: { $0.key < $1.key })
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
        }
    }

    /// High-water mark ensures progress never goes backward.
    private var progressHighWater: Double = 0

    private func updateProgress(_ phase: NativeScanProgress.Phase, progress: Double, status: String) {
        let clamped = max(progress, progressHighWater)
        progressHighWater = clamped
        scanProgress = NativeScanProgress(phase: phase, progress: clamped, status: status)
    }

    private func resetProgress() {
        progressHighWater = 0
        scanProgress = nil
    }

    /// Directory URL for persisted scanner state (chain-specific). Each scan
    /// appends new nullifiers / leaves to per-type log files inside, and only
    /// the small utxos.json + meta.json get rewritten. A legacy single-file
    /// `{name}.json` may sit alongside this directory; the loader migrates it
    /// transparently on first save.
    private nonisolated static func scannerStateURL(walletID: String, chainName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".railcart", isDirectory: true)
            .appendingPathComponent("native-scan", isDirectory: true)
            .appendingPathComponent("\(walletID)-\(chainName)", isDirectory: true)
    }

    /// Standard BIP39 seed: PBKDF2-SHA512(mnemonic, "mnemonic" + passphrase).
    private nonisolated static func bip39Seed(mnemonic: String, passphrase: String = "") -> String {
        let password = mnemonic.data(using: .utf8)!
        let salt = ("mnemonic" + passphrase).data(using: .utf8)!

        var derivedKey = Data(count: 64)
        _ = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        2048,
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        64
                    )
                }
            }
        }

        return derivedKey.map { String(format: "%02x", $0) }.joined()
    }

    private func resolveTokenAddress(tokenHash: BigUInt, chainName: String) -> String? {
        guard let chain = Chain(rawValue: chainName) else { return nil }

        // ERC20 token hash is the address zero-padded to 32 bytes — just compare as BigUInt
        for token in Token.supported {
            guard let address = token.address(on: chain) else { continue }
            let addrHex = address.lowercased().hasPrefix("0x")
                ? String(address.lowercased().dropFirst(2))
                : address.lowercased()
            if let addrBigUInt = BigUInt(addrHex, radix: 16),
               addrBigUInt == tokenHash {
                return address
            }
        }

        return nil
    }
}

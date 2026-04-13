import Foundation
import Observation
import RailcartCrypto
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
    private var scanners: [String: RailcartCrypto.Scanner] = [:]
    /// Cached key sets keyed by walletID (keys are chain-independent).
    private var keySets: [String: RailgunKeyDerivation.KeySet] = [:]
    /// Creation block numbers per wallet, for skipping pre-creation history.
    private var creationBlocks: [String: [String: Int]] = [:]

    private(set) var scanProgress: NativeScanProgress?
    private(set) var isScanning = false

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
    func scanAllWallets(chainName: String, walletIDs: [String]) async {
        isScanning = true
        resetProgress()

        // Phase 1: Load scanners (quick — just JSON from disk)
        updateProgress(.initializingKeys, progress: 0, status: "Loading wallet state...")

        for walletID in walletIDs {
            guard let keys = keySets[walletID] else { continue }
            let scannerKey = "\(walletID):\(chainName)"
            if scanners[scannerKey] == nil {
                let stateURL = Self.scannerStateURL(walletID: walletID, chainName: chainName)
                let scanner = await Task.detached(priority: .userInitiated) {
                    let s = RailcartCrypto.Scanner(keys: keys)
                    if FileManager.default.fileExists(atPath: stateURL.path) {
                        try? s.load(from: stateURL)
                    }
                    return s
                }.value
                if scanner.lastScannedBlock > 0 {
                    AppLogger.shared.log("native-scan", "Restored \(chainName) state for \(walletID.prefix(8))... (block \(scanner.lastScannedBlock), \(scanner.utxos.count) UTXOs)")
                }
                scanners[scannerKey] = scanner
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
                // Phase 3: Decrypt commitments (CPU-bound, most of the time)
                // This phase gets 0.35 – 0.92 of the progress bar
                let decryptStart = 0.35
                let decryptEnd = 0.92

                updateProgress(
                    .decryptingCommitments(processed: 0, total: totalCommitments),
                    progress: decryptStart,
                    status: "Decrypting \(totalCommitments) commitments..."
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
                                status: "Decrypting commitments: \(processed) / \(total)"
                            )
                        }
                    }

                    try await Task.detached(priority: .userInitiated) {
                        try await scanner.scan(chainName: chainName)
                    }.value
                }

                // Phase 4: Save state
                updateProgress(.computingBalances, progress: 0.93, status: "Saving scan state...")

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

    /// Get private balances for a wallet on a chain.
    func getPrivateBalances(chainName: String, walletID: String) -> [TokenBalance] {
        let scannerKey = "\(walletID):\(chainName)"
        guard let scanner = scanners[scannerKey] else { return [] }

        return scanner.balances.compactMap { balance -> TokenBalance? in
            guard let token = resolveTokenAddress(tokenHash: balance.tokenHash, chainName: chainName) else {
                return nil
            }
            return TokenBalance(tokenAddress: token, amount: String(balance.totalValue))
        }
    }

    func isInitialized(walletID: String) -> Bool {
        keySets[walletID] != nil
    }

    /// Clear saved scan state and in-memory scanners, forcing a full rescan from block 0.
    func clearSavedState(walletIDs: [String], chainName: String) {
        for walletID in walletIDs {
            let scannerKey = "\(walletID):\(chainName)"
            scanners.removeValue(forKey: scannerKey)
            let url = Self.scannerStateURL(walletID: walletID, chainName: chainName)
            try? FileManager.default.removeItem(at: url)
        }
        AppLogger.shared.log("native-scan", "Cleared scan state for \(chainName), will rescan from block 0")
    }

    // MARK: - Private

    /// Thread-safe counter for parallel fetch progress.
    private final class FetchCounts: Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

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

    /// File URL for persisted scanner state (chain-specific).
    private nonisolated static func scannerStateURL(walletID: String, chainName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".railcart", isDirectory: true)
            .appendingPathComponent("native-scan", isDirectory: true)
            .appendingPathComponent("\(walletID)-\(chainName).json")
    }

    /// Standard BIP39 seed: PBKDF2-SHA512(mnemonic, "mnemonic" + passphrase).
    private nonisolated static func bip39Seed(mnemonic: String, passphrase: String = "") -> String {
        let password = mnemonic.data(using: .utf8)!
        let salt = ("mnemonic" + passphrase).data(using: .utf8)!

        var derivedKey = Data(count: 64)
        derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
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

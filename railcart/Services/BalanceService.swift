//
//  BalanceService.swift
//  railcart
//
//  Caching layer for public and private balances.
//  Private balances are scanned once for all wallets and cached for 30 minutes.
//  Public balances are cached per-address for 5 minutes.
//

import Foundation
import Observation
import SwiftUI

private struct CacheEntry<T> {
    let value: T
    let timestamp: Date

    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(timestamp) > ttl
    }
}

@MainActor
@Observable
final class BalanceService {
    private let walletService: any WalletServiceProtocol
    let nativeScanner: NativeScannerService

    private static let publicTTL: TimeInterval = 300      // 5 minutes
    private static let privateTTL: TimeInterval = 1800     // 30 minutes

    // Cache keyed by "chain:address" for public balances
    private var ethBalanceCache: [String: CacheEntry<String>] = [:]
    private var erc20BalanceCache: [String: CacheEntry<[TokenBalance]>] = [:]

    // Cache keyed by "chain:walletID" for private balances
    private var privateBalanceCache: [String: CacheEntry<[TokenBalance]>] = [:]

    // POI aggregator URLs (resolved by the Node.js engine-init from remote config).
    // Fetched once lazily; the list rarely changes during a session.
    private var cachedPOINodeURLs: [URL]?

    // MARK: - Observable scan state

    /// Whether a private balance scan is currently running.
    private(set) var isScanning = false
    private(set) var scanStep: String?
    private(set) var scanProgress: Double = 0
    /// The chain currently being scanned for UI display purposes (nil if idle).
    private(set) var scanningChain: String?

    /// In-flight scan tasks keyed by chain name. Callers can await an existing scan
    /// instead of starting a duplicate.
    private var inFlightScans: [String: Task<Void, Never>] = [:]

    /// The currently executing scan task (only one scan runs at a time to avoid
    /// overloading the node process with concurrent merkletree rescans).

    /// Last known scan progress per chain, so switching back shows the most recent value.
    private var lastProgress: [String: (step: String?, progress: Double)] = [:]

    init(walletService: any WalletServiceProtocol) {
        self.walletService = walletService
        self.nativeScanner = NativeScannerService()
        nativeScanner.restorePersistedPOIProofState()
        subscribeToPOIProofProgress()
    }

    /// Wire the bridge's `poiProofProgress` stream into the scanner's
    /// observable proof-generation state. Called once per service lifetime.
    ///
    /// The SDK fires `poiProofProgress` events from *any* `refreshPOIsForTXIDVersion`
    /// invocation, not only our explicit `generatePOIProofs` submission — it
    /// runs at the end of balance decryption, provider loads, and a few other
    /// internal flows. We only want to react when the user has initiated a
    /// submission, so every event is gated on the chain being in `.running`
    /// state. The terminal `.succeeded` transition is owned by
    /// `generatePOIProofs` itself so SDK-internal refreshes can't clobber the
    /// persisted submission timestamp.
    private func subscribeToPOIProofProgress() {
        walletService.setOnPOIProofProgress { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let chainName = Chain.allCases.first(where: { $0.chainId == event.chainId })?.rawValue else {
                    return
                }
                // Ignore SDK events unless we're mid-submission for this
                // chain. Prevents SDK-internal POI refreshes from flashing
                // progress state or resetting the submit timestamp.
                guard case .running = self.nativeScanner.poiProofGen[chainName] else { return }

                switch event.status {
                case "AllProofsCompleted":
                    // Owned by generatePOIProofs — ignore to protect the
                    // persisted submission timestamp.
                    break
                case "Error":
                    let msg = event.errorMessage ?? "Proof generation failed"
                    self.nativeScanner.setPOIProofGen(chainName: chainName, .failed(message: msg, at: Date()))
                default:
                    // Map 0–100 SDK progress onto 0–1 for UI.
                    let step = event.totalCount > 0
                        ? " (\(event.index)/\(event.totalCount))"
                        : ""
                    let message = "Generating POI proofs\(step)"
                    self.nativeScanner.applyPOIProofProgress(
                        chainName: chainName,
                        progress: event.progress / 100,
                        status: nil,
                        message: message
                    )
                }
            }
        }
    }

    // MARK: - Public ETH Balance

    func getEthBalance(chainName: String, address: String) async throws -> String {
        let key = "\(chainName):\(address)"
        if let cached = ethBalanceCache[key], !cached.isExpired(ttl: Self.publicTTL) {
            return cached.value
        }
        let balance = try await walletService.getEthBalance(chainName: chainName, address: address)
        ethBalanceCache[key] = CacheEntry(value: balance, timestamp: Date())
        return balance
    }

    // MARK: - Public ERC-20 Balances

    func getERC20Balances(chainName: String, address: String, tokenAddresses: [String]) async throws -> [TokenBalance] {
        let key = "\(chainName):\(address)"
        if let cached = erc20BalanceCache[key], !cached.isExpired(ttl: Self.publicTTL) {
            return cached.value
        }
        let balances = try await walletService.getERC20Balances(
            chainName: chainName, address: address, tokenAddresses: tokenAddresses
        )
        erc20BalanceCache[key] = CacheEntry(value: balances, timestamp: Date())
        return balances
    }

    func invalidateERC20Balances(chainName: String, address: String) {
        erc20BalanceCache.removeValue(forKey: "\(chainName):\(address)")
    }

    // MARK: - Private RAILGUN Balances

    /// Return cached private balances if fresh, without triggering a scan.
    func cachedPrivateBalances(chainName: String, walletID: String) -> [TokenBalance]? {
        let key = "\(chainName):\(walletID)"
        guard let cached = privateBalanceCache[key], !cached.isExpired(ttl: Self.privateTTL) else { return nil }
        return cached.value
    }

    /// Scan the merkletree for all wallets on a chain and cache results.
    /// If a scan is already in flight for this chain, awaits that scan instead.
    /// Scans run to completion even if the user switches chains — node-side work
    /// can't be cancelled, so we always cache the results.
    /// Scan the merkletree for all wallets on a chain and cache results.
    /// If a scan is already in flight for this chain, awaits that scan instead.
    /// Multiple chains can scan concurrently — the native scanner has per-chain state.
    /// Automatically sets up scan UI state; callers don't need to call beginScanUI.
    func scanAllPrivateBalances(chainName: String, wallets: [Wallet]) async {
        let walletIDs = wallets.map(\.id)
        // If a scan is already in flight for this chain, wait for it
        if let existing = inFlightScans[chainName] {
            AppLogger.shared.log("sync", "Joining in-flight scan for \(chainName)")
            await existing.value
            return
        }

        beginScanUI(chainName: chainName)

        let task = Task {
            AppLogger.shared.log("sync", "Starting native private balance sync for \(chainName) (\(walletIDs.count) wallets)")

            // Initialize native scanner for any wallets that haven't been set up yet
            for wallet in wallets {
                if !nativeScanner.isInitialized(walletID: wallet.id) {
                    await initializeNativeScanner(wallet: wallet)
                }
            }

            // Observe native scanner progress and forward to our scan UI state
            let progressTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    if let progress = self.nativeScanner.scanProgress {
                        self.scanStep = progress.status
                        self.scanProgress = progress.progress
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            // Only query the POI aggregator on chains where POI is active;
            // non-POI chains (Sepolia) have no POI concept and the aggregator
            // returns Missing for everything, landing UTXOs in the wrong
            // bucket.
            let poiURLs: [URL] = Chain(rawValue: chainName)?.isPOIActive == true
                ? await resolvedPOINodeURLs()
                : []
            await nativeScanner.scanAllWallets(chainName: chainName, walletIDs: walletIDs, poiNodeURLs: poiURLs)
            progressTask.cancel()

            // Cache results from native scanner
            for walletID in walletIDs {
                let balances = nativeScanner.getPrivateBalances(chainName: chainName, walletID: walletID)
                let key = "\(chainName):\(walletID)"
                privateBalanceCache[key] = CacheEntry(value: balances, timestamp: Date())
            }

            AppLogger.shared.log("sync", "Native private balance sync complete for \(chainName)")

            inFlightScans.removeValue(forKey: chainName)
            lastProgress.removeValue(forKey: chainName)

            if scanningChain == chainName {
                isScanning = false
                scanStep = nil
                scanProgress = 0
                scanningChain = nil
            }
        }
        inFlightScans[chainName] = task
        await task.value
    }

    /// Whether all wallets on a chain have fresh cached private balances.
    func hasAllPrivateBalances(chainName: String, walletIDs: [String]) -> Bool {
        walletIDs.allSatisfy { cachedPrivateBalances(chainName: chainName, walletID: $0) != nil }
    }

    /// Incremented each time a new scan starts; listeners use this to reset their state.
    private(set) var scanGeneration = 0

    /// Reset scan UI state when switching chains.
    /// Does NOT cancel in-flight node scans — they run to completion and cache results.
    func resetScanState() {
        if let scanningChain {
            AppLogger.shared.log("sync", "Switching away from \(scanningChain)")
        }
        isScanning = false
        scanStep = nil
        scanProgress = 0
        scanningChain = nil
    }

    /// Set the chain that scan UI should display for, and show scanning state.
    /// Restores last known progress if this chain has an in-flight scan.
    func beginScanUI(chainName: String) {
        scanningChain = chainName
        isScanning = true
        if let last = lastProgress[chainName] {
            scanStep = last.step
            scanProgress = last.progress
        } else {
            scanStep = "Scanning merkletree..."
            scanProgress = 0
        }
        scanGeneration += 1
    }

    // MARK: - Cache Invalidation

    func invalidateEthBalance(chainName: String, address: String) {
        ethBalanceCache.removeValue(forKey: "\(chainName):\(address)")
    }

    // MARK: - Stale token tracking

    /// Tokens with a pending transaction whose balance is out of date.
    /// Key: "chain:walletID:tokenAddress", value: expiry time.
    private(set) var staleTokens: [String: Date] = [:]

    /// Mark a token's private balance as stale (pending tx, balance will be out of date).
    func markTokenStale(chainName: String, walletID: String, tokenAddress: String, duration: TimeInterval = 300) {
        let key = "\(chainName):\(walletID):\(tokenAddress.lowercased())"
        staleTokens[key] = Date().addingTimeInterval(duration)
    }

    /// Check if a token's private balance is stale.
    func isTokenStale(chainName: String, walletID: String, tokenAddress: String) -> Bool {
        let key = "\(chainName):\(walletID):\(tokenAddress.lowercased())"
        guard let expiry = staleTokens[key] else { return false }
        if Date() > expiry {
            staleTokens.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Clear stale marker for a token (e.g. after a successful rescan picks up the change).
    func clearStale(chainName: String, walletID: String, tokenAddress: String) {
        let key = "\(chainName):\(walletID):\(tokenAddress.lowercased())"
        staleTokens.removeValue(forKey: key)
    }

    func invalidatePrivateBalances(chainName: String, walletID: String) {
        privateBalanceCache.removeValue(forKey: "\(chainName):\(walletID)")
    }

    func invalidateAllPrivateBalances(chainName: String) {
        privateBalanceCache = privateBalanceCache.filter { !$0.key.hasPrefix("\(chainName):") }
    }

    func invalidateChain(_ chainName: String) {
        ethBalanceCache = ethBalanceCache.filter { !$0.key.hasPrefix("\(chainName):") }
        erc20BalanceCache = erc20BalanceCache.filter { !$0.key.hasPrefix("\(chainName):") }
        privateBalanceCache = privateBalanceCache.filter { !$0.key.hasPrefix("\(chainName):") }
    }

    /// Initialize the native scanner for a wallet by fetching its mnemonic.
    func initializeNativeScanner(wallet: Wallet) async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            AppLogger.shared.log("native-scan", "Cannot init scanner: no encryption key")
            return
        }
        do {
            let mnemonic = try await walletService.getWalletMnemonic(
                encryptionKey: encryptionKey, walletID: wallet.id
            )
            await nativeScanner.initializeWallet(
                walletID: wallet.id,
                mnemonic: mnemonic,
                derivationIndex: wallet.derivationIndex,
                creationBlockNumbers: wallet.creationBlockNumbers
            )
            AppLogger.shared.log("native-scan", "Initialized native scanner for wallet \(wallet.id.prefix(8))...")
        } catch {
            AppLogger.shared.log("native-scan", "Failed to init scanner for wallet: \(error.localizedDescription)")
        }
    }

    func invalidateAll() {
        ethBalanceCache.removeAll()
        erc20BalanceCache.removeAll()
        privateBalanceCache.removeAll()
    }

    // MARK: - POI

    /// Resolve POI aggregator URLs via the bridge. Returns `[]` on any failure
    /// so scanning degrades gracefully (UTXOs keep their default `.spendable`
    /// bucket, same as pre-POI behavior).
    private func resolvedPOINodeURLs() async -> [URL] {
        if let cached = cachedPOINodeURLs { return cached }
        do {
            let urls = try await walletService.getPOINodeURLs().compactMap { URL(string: $0) }
            cachedPOINodeURLs = urls
            return urls
        } catch {
            AppLogger.shared.log("native-scan", "getPOINodeURLs failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Trigger POI proof generation + submission for every wallet on this
    /// chain. Runs the SDK's `generatePOIsForWallet` pipeline (refresh received
    /// POI status, submit legacy transact POI events, refresh spent POI status,
    /// auto-generate and submit transact/unshield POI proofs). Progress is
    /// streamed through `nativeScanner.poiProofGen[chainName]` via the
    /// `poiProofProgress` bridge event. After submission, re-queries POI
    /// statuses so any newly-`Valid` UTXOs hit token cards immediately.
    func generatePOIProofs(chainName: String, wallets: [Wallet]) async {
        guard !wallets.isEmpty else { return }
        guard Chain(rawValue: chainName)?.isPOIActive == true else { return }
        if case .running = nativeScanner.poiProofGen[chainName] { return }

        // Snapshot which blinded commitments are Missing at submit time so
        // we can detect later if new Missing ones arrive (e.g. another
        // broadcaster tx post-submit).
        let walletIDs = wallets.map(\.id)
        let snapshot = nativeScanner.missingPOIBlindedCommitments(
            chainName: chainName, walletIDs: walletIDs
        )

        nativeScanner.setPOIProofGen(
            chainName: chainName,
            .running(progress: 0, message: "Starting POI proof generation…")
        )

        do {
            for wallet in wallets {
                try await walletService.generatePOIProofs(chainName: chainName, walletID: wallet.id)
            }
            // SDK may not emit AllProofsCompleted for every flow (e.g. no
            // proofs to generate). Set a successful terminal state here as
            // a fallback; a later AllProofsCompleted event is harmless.
            nativeScanner.setPOIProofGen(
                chainName: chainName,
                .succeeded(at: Date()),
                submittedBlindedCommitments: snapshot
            )
        } catch {
            nativeScanner.setPOIProofGen(
                chainName: chainName,
                .failed(message: error.localizedDescription, at: Date())
            )
            return
        }

        // Pull fresh statuses so any newly-Valid UTXOs show up in token cards.
        await refreshPOIStatus(chainName: chainName, wallets: wallets)
    }

    /// User-initiated POI refresh without a full scan. Re-queries the POI
    /// aggregator for existing UTXOs and repopulates the private balance
    /// cache so newly-spendable funds appear in token cards without waiting
    /// for the next 30 min cache refresh.
    func refreshPOIStatus(chainName: String, wallets: [Wallet]) async {
        guard !wallets.isEmpty else { return }
        // Only makes sense on POI-active chains — on testnets the scanner
        // leaves every UTXO as .spendable so there's nothing to update.
        guard Chain(rawValue: chainName)?.isPOIActive == true else { return }
        // If a POI query is already in flight (via scan or earlier retry),
        // don't stampede. The caller's observable state will pick up the
        // result of the running query.
        if case .querying = nativeScanner.poiStatus[chainName] { return }

        let urls = await resolvedPOINodeURLs()
        guard !urls.isEmpty else { return }

        let walletIDs = wallets.map(\.id)
        await nativeScanner.refreshPOIStatuses(
            chainName: chainName, walletIDs: walletIDs, poiNodeURLs: urls
        )

        // Repopulate caches so token cards pick up any bucket changes.
        for walletID in walletIDs {
            let balances = nativeScanner.getPrivateBalances(chainName: chainName, walletID: walletID)
            privateBalanceCache["\(chainName):\(walletID)"] = CacheEntry(value: balances, timestamp: Date())
        }
    }
}

// MARK: - Environment Key

private struct BalanceServiceKey: EnvironmentKey {
    static let defaultValue: BalanceService? = nil
}

extension EnvironmentValues {
    var balanceService: BalanceService? {
        get { self[BalanceServiceKey.self] }
        set { self[BalanceServiceKey.self] = newValue }
    }
}

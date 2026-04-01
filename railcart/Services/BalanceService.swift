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

    private static let publicTTL: TimeInterval = 300      // 5 minutes
    private static let privateTTL: TimeInterval = 1800     // 30 minutes

    // Cache keyed by "chain:address" for public balances
    private var ethBalanceCache: [String: CacheEntry<String>] = [:]
    private var erc20BalanceCache: [String: CacheEntry<[TokenBalance]>] = [:]

    // Cache keyed by "chain:walletID" for private balances
    private var privateBalanceCache: [String: CacheEntry<[TokenBalance]>] = [:]

    // MARK: - Observable scan state

    /// Whether a private balance scan is currently running.
    private(set) var isScanning = false
    private(set) var scanStep: String?
    private(set) var scanProgress: Double = 0

    init(walletService: any WalletServiceProtocol) {
        self.walletService = walletService
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
    /// This is the single entry point for private balance scanning.
    /// Views should observe `isScanning` / `scanProgress` for UI state.
    func scanAllPrivateBalances(chainName: String, walletIDs: [String]) async {
        guard !isScanning else { return }
        isScanning = true
        scanStep = "Scanning merkletree..."
        scanProgress = 0
        scanGeneration += 1

        AppLogger.shared.log("sync", "Starting private balance sync for \(chainName) (\(walletIDs.count) wallets)")
        do {
            try await walletService.scanBalances(chainName: chainName, walletIDs: walletIDs)
            for walletID in walletIDs {
                let balances = try await walletService.getPrivateBalances(chainName: chainName, walletID: walletID)
                let key = "\(chainName):\(walletID)"
                privateBalanceCache[key] = CacheEntry(value: balances, timestamp: Date())
            }
            AppLogger.shared.log("sync", "Private balance sync complete for \(chainName)")
        } catch {
            AppLogger.shared.log("error", "Private balance sync failed for \(chainName): \(error.localizedDescription)")
        }

        isScanning = false
        scanStep = nil
    }

    /// Whether all wallets on a chain have fresh cached private balances.
    func hasAllPrivateBalances(chainName: String, walletIDs: [String]) -> Bool {
        walletIDs.allSatisfy { cachedPrivateBalances(chainName: chainName, walletID: $0) != nil }
    }

    /// Update scan progress from external events (e.g. NodeBridge scanProgress events).
    func updateScanProgress(step: String?, progress: Double) {
        guard isScanning else { return }
        if let step { scanStep = step }
        if progress > scanProgress { scanProgress = progress }
    }

    /// Incremented each time a new scan starts; listeners use this to reset their state.
    private(set) var scanGeneration = 0

    // MARK: - Cache Invalidation

    func invalidateEthBalance(chainName: String, address: String) {
        ethBalanceCache.removeValue(forKey: "\(chainName):\(address)")
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

    func invalidateAll() {
        ethBalanceCache.removeAll()
        erc20BalanceCache.removeAll()
        privateBalanceCache.removeAll()
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

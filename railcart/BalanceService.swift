//
//  BalanceService.swift
//  railcart
//
//  Caching layer for public and private balances.
//  Cache entries expire after 5 minutes and can be invalidated manually.
//

import Foundation
import Observation
import SwiftUI

private struct CacheEntry<T> {
    let value: T
    let timestamp: Date

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 300  // 5 minutes
    }
}

@MainActor
@Observable
final class BalanceService {
    private let walletService: any WalletServiceProtocol

    // Cache keyed by "chain:address" for public balances
    private var ethBalanceCache: [String: CacheEntry<String>] = [:]

    // Cache keyed by "chain:walletID" for private balances
    private var privateBalanceCache: [String: CacheEntry<[TokenBalance]>] = [:]

    init(walletService: any WalletServiceProtocol) {
        self.walletService = walletService
    }

    // MARK: - Public ETH Balance

    /// Get public ETH balance for an address on a chain.
    /// Returns cached value if fresh, otherwise fetches.
    func getEthBalance(chainName: String, address: String) async throws -> String {
        let key = "\(chainName):\(address)"
        if let cached = ethBalanceCache[key], !cached.isExpired {
            return cached.value
        }
        let balance = try await walletService.getEthBalance(chainName: chainName, address: address)
        ethBalanceCache[key] = CacheEntry(value: balance, timestamp: Date())
        return balance
    }

    // MARK: - Private RAILGUN Balances

    /// Get private token balances for a wallet on a chain.
    /// Returns cached value if fresh, otherwise scans and fetches.
    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance] {
        let key = "\(chainName):\(walletID)"
        if let cached = privateBalanceCache[key], !cached.isExpired {
            return cached.value
        }
        let balances = try await walletService.scanAndGetBalances(chainName: chainName, walletID: walletID)
        privateBalanceCache[key] = CacheEntry(value: balances, timestamp: Date())
        return balances
    }

    // MARK: - Cache Invalidation

    /// Invalidate public balance cache for a specific address on a chain.
    func invalidateEthBalance(chainName: String, address: String) {
        ethBalanceCache.removeValue(forKey: "\(chainName):\(address)")
    }

    /// Invalidate private balance cache for a wallet on a chain.
    func invalidatePrivateBalances(chainName: String, walletID: String) {
        privateBalanceCache.removeValue(forKey: "\(chainName):\(walletID)")
    }

    /// Invalidate all cached balances for a chain.
    func invalidateChain(_ chainName: String) {
        ethBalanceCache = ethBalanceCache.filter { !$0.key.hasPrefix("\(chainName):") }
        privateBalanceCache = privateBalanceCache.filter { !$0.key.hasPrefix("\(chainName):") }
    }

    /// Invalidate all cached balances.
    func invalidateAll() {
        ethBalanceCache.removeAll()
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

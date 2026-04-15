//
//  NetworkState.swift
//  railcart
//
//  Global network selection state shared across all views.
//

import Foundation
import Observation

struct ProviderError: Equatable {
    let chain: Chain
    let message: String
}

enum Chain: String, CaseIterable, Identifiable, Sendable {
    case ethereum
    case sepolia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ethereum: "Ethereum"
        case .sepolia: "Sepolia"
        }
    }

    var chainId: Int {
        switch self {
        case .ethereum: 1
        case .sepolia: 11155111
        }
    }

    var isTestnet: Bool {
        self == .sepolia
    }

    /// Whether POI (Proof of Innocence) is enforced for spending on this chain.
    /// Only `.spendable` UTXOs may be selected for transactions when true.
    var isPOIActive: Bool {
        switch self {
        case .ethereum: true
        case .sepolia: false
        }
    }
}

@MainActor
@Observable
final class NetworkState {
    var selectedChain: Chain = {
        #if DEBUG
        .sepolia
        #else
        .ethereum
        #endif
    }()

    /// Chains whose RPC provider has been loaded into the RAILGUN engine.
    private(set) var loadedChains: Set<Chain> = []

    /// Chains currently being loaded (prevents concurrent attempts).
    private var loadingChains: Set<Chain> = []

    /// Set when all RPC providers fail for a chain. Cleared on successful load.
    var providerError: ProviderError?

    /// User-configured custom RPC URLs per chain, persisted in UserDefaults.
    private(set) var customRPCURLs: [Chain: String] = [:]

    private static let customRPCKey = "network.customRPCURLs"

    init() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.customRPCKey) as? [String: String] {
            for (key, value) in dict {
                if let chain = Chain(rawValue: key) {
                    customRPCURLs[chain] = value
                }
            }
        }
    }

    func setCustomRPCURL(_ url: String, for chain: Chain) {
        customRPCURLs[chain] = url
        persistCustomRPCURLs()
    }

    func removeCustomRPCURL(for chain: Chain) {
        customRPCURLs.removeValue(forKey: chain)
        persistCustomRPCURLs()
    }

    func clearCustomRPCURLs() {
        customRPCURLs.removeAll()
        persistCustomRPCURLs()
    }

    /// Remove a chain from the loaded set so the next `ensureProviderLoaded`
    /// call re-loads it (e.g. after changing the custom RPC URL).
    func invalidateProvider(for chain: Chain) {
        loadedChains.remove(chain)
    }

    /// Load the RPC provider for a chain if it hasn't been loaded yet.
    /// Returns immediately if already loaded.
    ///
    /// Prefers a user-configured custom RPC URL. Falls back to the on-chain
    /// RAILGUN remote config (multiple providers with built-in failover).
    func ensureProviderLoaded(for chain: Chain, using service: any WalletServiceProtocol) async throws {
        guard !loadedChains.contains(chain) else { return }
        // If another caller is already loading this chain, wait for it instead
        // of firing a concurrent request that races and may flash an error.
        guard !loadingChains.contains(chain) else { return }
        loadingChains.insert(chain)
        defer { loadingChains.remove(chain) }

        do {
            if let customURL = customRPCURLs[chain], !customURL.isEmpty {
                try await service.loadChainProvider(chainName: chain.rawValue, providerUrl: customURL)
            } else {
                try await service.loadChainProviderFromRemoteConfig(chainName: chain.rawValue)
            }
            loadedChains.insert(chain)
            providerError = nil
        } catch {
            providerError = ProviderError(chain: chain, message: error.localizedDescription)
            throw error
        }
    }

    private func persistCustomRPCURLs() {
        let dict = Dictionary(uniqueKeysWithValues: customRPCURLs.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(dict, forKey: Self.customRPCKey)
    }
}

//
//  NetworkState.swift
//  railcart
//
//  Global network selection state shared across all views.
//

import Foundation
import Observation

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

    /// Load the RPC provider for a chain if it hasn't been loaded yet.
    /// Returns immediately if already loaded.
    func ensureProviderLoaded(for chain: Chain, using service: any WalletServiceProtocol) async throws {
        guard !loadedChains.contains(chain) else { return }

        // Prefer the RPC URLs published in the on-chain RAILGUN remote config
        // (multiple providers per chain with built-in fallback). Fall back to
        // the hardcoded Config.chainProviders entry if the remote config has
        // no entry for this chain or the call fails.
        do {
            try await service.loadChainProviderFromRemoteConfig(chainName: chain.rawValue)
            loadedChains.insert(chain)
            return
        } catch {
            // Fall through to hardcoded provider
        }

        guard let url = Config.chainProviders[chain.rawValue], !url.isEmpty else { return }
        try await service.loadChainProvider(chainName: chain.rawValue, providerUrl: url)
        loadedChains.insert(chain)
    }
}

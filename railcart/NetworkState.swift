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
}

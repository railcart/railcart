//
//  Constants.swift
//  railcart
//
//  Build-scheme-dependent configuration.
//

import Foundation

enum Config {
    /// RPC provider URLs per chain. All chains are loaded on startup.
    static let chainProviders: [String: String] = [
        "ethereum": "https://eth.llamarpc.com",
        "sepolia": "https://eth.llamarpc.com",
    ]
}

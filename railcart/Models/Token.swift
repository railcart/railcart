//
//  Token.swift
//  railcart
//
//  Known token definitions with per-chain contract addresses.
//

import Foundation

struct Token: Identifiable, Sendable {
    let symbol: String
    let name: String
    let decimals: Int
    let iconAsset: String  // Asset catalog image name (e.g. "TokenIcons/token-eth")
    let addresses: [Chain: String]

    var id: String { symbol }

    func address(on chain: Chain) -> String? {
        addresses[chain]
    }

    func formatBalance(_ wei: String) -> String {
        guard let value = Decimal(string: wei), value != 0 else { return "0.00" }
        let divisor = pow(Decimal(10), decimals)
        let amount = value / divisor
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = decimals <= 6 ? 2 : 6
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: amount as NSDecimalNumber) ?? "0.00"
    }
}

extension Token {
    /// Native ETH (not an ERC-20, but useful for icon lookup).
    static let eth = Token(
        symbol: "ETH",
        name: "Ether",
        decimals: 18,
        iconAsset: "TokenIcons/token-eth",
        addresses: [:]
    )

    static let weth = Token(
        symbol: "WETH",
        name: "Wrapped Ether",
        decimals: 18,
        iconAsset: "TokenIcons/token-weth",
        addresses: [
            .ethereum: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
            .sepolia: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
        ]
    )

    static let usdc = Token(
        symbol: "USDC",
        name: "USD Coin",
        decimals: 6,
        iconAsset: "TokenIcons/token-usdc",
        addresses: [
            .ethereum: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            .sepolia: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
        ]
    )

    static let usdt = Token(
        symbol: "USDT",
        name: "Tether",
        decimals: 6,
        iconAsset: "TokenIcons/token-usdt",
        addresses: [
            .ethereum: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
            .sepolia: "0x7169D38820dfd117C3FA1f22a697dBA58d90BA06",
        ]
    )

    /// All supported tokens for display in the wallet view.
    static let supported: [Token] = [.weth, .usdc, .usdt]

    /// Find the token metadata for a given contract address (case-insensitive).
    static func forAddress(_ address: String, on chain: Chain) -> Token? {
        supported.first { token in
            token.address(on: chain)?.lowercased() == address.lowercased()
        }
    }
}

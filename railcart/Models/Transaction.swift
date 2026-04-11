//
//  Transaction.swift
//  railcart
//
//  Local record of wallet transactions (shield, unshield, private send).
//  Persisted to UserDefaults — not synced from chain.
//

import Foundation

struct Transaction: Codable, Identifiable, Sendable {
    let id: String
    let action: Action
    let chainName: String
    let txHash: String
    let timestamp: Date
    let tokenSymbol: String
    let amount: String           // human-readable (e.g. "0.5")
    let fromWalletID: String    // wallet ID
    let fromAddress: String      // public ETH address or railgun address
    let toAddress: String        // destination address

    enum CodingKeys: String, CodingKey {
        case id, action, chainName, txHash, timestamp, tokenSymbol, amount
        case fromWalletID = "fromAccountID"
        case fromAddress, toAddress
    }

    enum Action: String, Codable, Sendable {
        case shield
        case unshield
        case privateSend
    }

    // MARK: - Persistence

    private static let storageKey = "wallet.transactions"

    static func loadAll() -> [Transaction] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let txs = try? JSONDecoder().decode([Transaction].self, from: data) else {
            return []
        }
        return txs
    }

    static func saveAll(_ transactions: [Transaction]) {
        if let data = try? JSONEncoder().encode(transactions) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

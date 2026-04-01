//
//  Account.swift
//  railcart
//
//  A wallet account derived from the HD seed at a specific BIP-44 index.
//

import Foundation

struct Account: Codable, Identifiable, Sendable {
    let id: String               // railgunWalletID from the SDK
    let derivationIndex: Int     // BIP-44 index (0, 1, 2, ...)
    let railgunAddress: String   // 0zk privacy address
    var name: String             // user-editable label

    /// In-memory only (not persisted). Populated on unlock.
    struct Unlocked: Sendable {
        let ethAddress: String
        let ethPrivateKey: String
    }

    // MARK: - Persistence

    private static let storageKey = "wallet.accounts"
    static var defaults: UserDefaults = .standard

    static func loadAll() -> [Account] {
        guard let data = defaults.data(forKey: storageKey),
              let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            return []
        }
        return accounts
    }

    static func saveAll(_ accounts: [Account]) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

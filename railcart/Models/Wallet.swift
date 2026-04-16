//
//  Wallet.swift
//  railcart
//
//  A wallet derived from the HD seed at a specific BIP-44 index.
//

import Foundation

struct Wallet: Codable, Identifiable, Sendable {
    let id: String               // railgunWalletID from the SDK
    let derivationIndex: Int     // BIP-44 index (0, 1, 2, ...)
    let railgunAddress: String   // 0zk privacy address
    var name: String             // user-editable label
    /// Block numbers at wallet creation time, per chain name.
    /// Used to skip scanning before the wallet existed.
    var creationBlockNumbers: [String: Int]?

    /// In-memory only (not persisted). Populated on unlock.
    struct Unlocked: Sendable {
        let ethAddress: String
        let ethPrivateKey: String
    }

    // MARK: - Persistence

    private static let storageKey = "wallet.accounts"

    static func loadAll() -> [Wallet] {
        guard let data = RailcartDefaults.store.data(forKey: storageKey),
              let wallets = try? JSONDecoder().decode([Wallet].self, from: data) else {
            return []
        }
        return wallets
    }

    static func saveAll(_ wallets: [Wallet]) {
        if let data = try? JSONEncoder().encode(wallets) {
            RailcartDefaults.store.set(data, forKey: storageKey)
        }
    }
}

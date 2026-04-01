//
//  TransactionStore.swift
//  railcart
//
//  Observable store for local transaction history.
//

import Foundation
import Observation

@MainActor
@Observable
final class TransactionStore {
    var transactions: [Transaction] = Transaction.loadAll() {
        didSet { if !isPreview { Transaction.saveAll(transactions) } }
    }

    private var isPreview = false

    func record(_ tx: Transaction) {
        transactions.insert(tx, at: 0)
    }

    /// Set transactions without persisting to UserDefaults. For previews only.
    func setForPreview(_ txs: [Transaction]) {
        isPreview = true
        transactions = txs
    }

    /// Transactions filtered by chain.
    func transactions(for chainName: String) -> [Transaction] {
        transactions.filter { $0.chainName == chainName }
    }
}

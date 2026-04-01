//
//  WalletState.swift
//  railcart
//
//  Observable wallet unlock state that persists across view navigation.
//

import Foundation
import Observation

@MainActor
@Observable
final class WalletState {
    enum Step {
        case initial
        case enterPassword
        case showMnemonic
        case unlock
        case ready
    }

    private(set) var step: Step = .initial

    /// Persisted account metadata (names, IDs, indices, railgun addresses).
    var accounts: [Account] = Account.loadAll() {
        didSet { if !isPreview { Account.saveAll(accounts) } }
    }

    /// In-memory unlocked keys, keyed by account ID. Cleared on lock.
    var unlockedKeys: [String: Account.Unlocked] = [:]

    /// Shared wallet state (same across all accounts from same seed).
    var mnemonic: String?

    var showImportSheet = false

    private var lockTimer: Timer?
    private var isPreview = false

    /// The next derivation index to use when adding a new account.
    var nextDerivationIndex: Int {
        (accounts.map(\.derivationIndex).max() ?? -1) + 1
    }

    func setStep(_ newStep: Step) {
        step = newStep
        if newStep == .ready {
            startLockTimer()
        }
    }

    func lock() {
        lockTimer?.invalidate()
        lockTimer = nil
        unlockedKeys.removeAll()
        step = .unlock
    }

    func addAccount(_ account: Account, unlocked: Account.Unlocked) {
        accounts.append(account)
        unlockedKeys[account.id] = unlocked
    }

    func unlockAccount(_ account: Account, with keys: Account.Unlocked) {
        unlockedKeys[account.id] = keys
    }

    func account(byID id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    /// Set accounts without triggering UserDefaults persistence. For previews only.
    func setAccountsForPreview(_ newAccounts: [Account]) {
        isPreview = true
        accounts = newAccounts
    }

    private func startLockTimer() {
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lock()
            }
        }
    }
}

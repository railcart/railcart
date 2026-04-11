//
//  WalletState.swift
//  railcart
//
//  Observable wallet unlock state that persists across view navigation.
//

import AppKit
import Foundation
import Observation

enum LockTimeout: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case never = "never"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .never: "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .oneHour: 3600
        case .never: nil
        }
    }

    private static let defaultsKey = "lockTimeout"

    static var saved: LockTimeout {
        guard let raw = Account.defaults.string(forKey: defaultsKey),
              let value = LockTimeout(rawValue: raw) else { return .fiveMinutes }
        return value
    }

    static func save(_ value: LockTimeout) {
        Account.defaults.set(value.rawValue, forKey: defaultsKey)
    }
}

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

    var lockTimeout: LockTimeout = .saved {
        didSet {
            LockTimeout.save(lockTimeout)
            if step == .ready { startLockTimer() }
        }
    }

    var showImportSheet = false
    var isAddingWallet = false
    #if DEBUG
    var showReplaceMnemonicSheet = false
    #endif

    private var lockTimer: Timer?
    private var lockPending = false
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

    func addWallet(using service: any WalletServiceProtocol) async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey),
              let firstAccount = accounts.first else { return }

        isAddingWallet = true
        defer { isAddingWallet = false }

        let index = nextDerivationIndex

        do {
            let mnemonic = try await service.getWalletMnemonic(
                encryptionKey: encryptionKey,
                walletID: firstAccount.id
            )

            var creationBlocks: [String: Int] = [:]
            for chainName in Chain.allCases.map(\.rawValue) {
                if let block = try? await service.getBlockNumber(chainName: chainName) {
                    creationBlocks[chainName] = block
                }
            }

            let walletInfo = try await service.createWallet(
                encryptionKey: encryptionKey,
                mnemonic: mnemonic,
                derivationIndex: index,
                creationBlockNumbers: creationBlocks
            )

            let account = Account(
                id: walletInfo.id,
                derivationIndex: walletInfo.derivationIndex,
                railgunAddress: walletInfo.railgunAddress,
                name: "Wallet \(index + 1)"
            )
            let unlocked = Account.Unlocked(
                ethAddress: walletInfo.ethAddress,
                ethPrivateKey: walletInfo.ethPrivateKey
            )
            addAccount(account, unlocked: unlocked)
        } catch {
            // TODO: surface error to user
        }
    }

    /// Lock immediately if the app is active, otherwise defer until foregrounded.
    func handleAppActivation() {
        guard lockPending else { return }
        lockPending = false
        lock()
    }

    private func startLockTimer() {
        lockTimer?.invalidate()
        lockTimer = nil
        guard let interval = lockTimeout.interval else { return }
        lockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NSApplication.shared.isActive {
                    self.lock()
                } else {
                    self.lockPending = true
                }
            }
        }
    }
}

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
    var isAddingWallet = false
    #if DEBUG
    var showReplaceMnemonicSheet = false
    #endif

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

    private func startLockTimer() {
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lock()
            }
        }
    }
}

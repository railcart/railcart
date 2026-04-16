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
        guard let raw = RailcartDefaults.store.string(forKey: defaultsKey),
              let value = LockTimeout(rawValue: raw) else { return .fiveMinutes }
        return value
    }

    static func save(_ value: LockTimeout) {
        RailcartDefaults.store.set(value.rawValue, forKey: defaultsKey)
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

    /// Persisted wallet metadata (names, IDs, indices, railgun addresses).
    var wallets: [Wallet] = Wallet.loadAll() {
        didSet { if !isPreview { Wallet.saveAll(wallets) } }
    }

    /// In-memory unlocked keys, keyed by wallet ID. Cleared on lock.
    var unlockedKeys: [String: Wallet.Unlocked] = [:]

    /// Shared wallet state (same across all wallets from same seed).
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

    /// The next derivation index to use when adding a new wallet.
    var nextDerivationIndex: Int {
        (wallets.map(\.derivationIndex).max() ?? -1) + 1
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

    func addWallet(_ wallet: Wallet, unlocked: Wallet.Unlocked) {
        wallets.append(wallet)
        unlockedKeys[wallet.id] = unlocked
    }

    func unlockWallet(_ wallet: Wallet, with keys: Wallet.Unlocked) {
        unlockedKeys[wallet.id] = keys
    }

    func wallet(byID id: String) -> Wallet? {
        wallets.first { $0.id == id }
    }

    /// Set wallets without triggering UserDefaults persistence. For previews only.
    func setWalletsForPreview(_ newWallets: [Wallet]) {
        isPreview = true
        wallets = newWallets
    }

    func addWallet(using service: any WalletServiceProtocol, keychain: any KeychainProviding) async {
        guard let encryptionKey = keychain.load(.encryptionKey),
              let firstWallet = wallets.first else { return }

        isAddingWallet = true
        defer { isAddingWallet = false }

        let index = nextDerivationIndex

        do {
            let mnemonic = try await service.getWalletMnemonic(
                encryptionKey: encryptionKey,
                walletID: firstWallet.id
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

            let newWallet = Wallet(
                id: walletInfo.id,
                derivationIndex: walletInfo.derivationIndex,
                railgunAddress: walletInfo.railgunAddress,
                name: "Wallet \(index + 1)",
                creationBlockNumbers: creationBlocks
            )
            let unlocked = Wallet.Unlocked(
                ethAddress: walletInfo.ethAddress,
                ethPrivateKey: walletInfo.ethPrivateKey
            )
            addWallet(newWallet, unlocked: unlocked)
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

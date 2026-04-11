//
//  WalletSetupView.swift
//  railcart
//
//  Wallet creation and unlock flow.
//

import SwiftUI

struct WalletSetupView: View {
    @Environment(\.walletService) private var service
    @Environment(WalletState.self) private var wallet

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            switch wallet.step {
            case .initial:
                ProgressView("Checking wallet...")
                    .task { checkExistingWallet() }

            case .enterPassword:
                createWalletView

            case .showMnemonic:
                mnemonicBackupView

            case .unlock:
                unlockWalletView

            case .ready:
                // Shouldn't be shown standalone — WalletDetailView handles this
                Text("Wallet unlocked")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 300)
    }

    // MARK: - Create Wallet

    private var createWalletView: some View {
        VStack(spacing: 16) {
            Text("Create Wallet")
                .font(.title2.bold())
            Text("Choose a password to encrypt your wallet.")
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("walletSetup.password")

            SecureField("Confirm Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("walletSetup.confirmPassword")

            Button("Create Wallet") {
                Task { await createWallet() }
            }
            .disabled(password.isEmpty || password != confirmPassword || isWorking)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("walletSetup.createButton")

            if password != confirmPassword && !confirmPassword.isEmpty {
                Text("Passwords don't match")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Mnemonic Backup

    private var mnemonicBackupView: some View {
        VStack(spacing: 16) {
            Text("Backup Your Recovery Phrase")
                .font(.title2.bold())

            Text("Write down these words in order. You will need them to recover your wallet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if let mnemonic = wallet.mnemonic {
                let words = mnemonic.split(separator: " ")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 4) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Text(word)
                                .font(.body.monospaced())
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: 400)
            }

            Button("I've Saved My Recovery Phrase") {
                Task { await finalizeWallet() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            .accessibilityIdentifier("walletSetup.savedMnemonicButton")

            if isWorking {
                ProgressView("Creating wallet...")
            }
        }
    }

    // MARK: - Unlock Wallet

    private var unlockWalletView: some View {
        VStack(spacing: 16) {
            Text("Unlock Wallet")
                .font(.title2.bold())
            Text("Enter your password to load your wallets.")
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { Task { await unlockWallets() } }

            HStack(spacing: 12) {
                Button("Unlock") {
                    Task { await unlockWallets() }
                }
                .disabled(password.isEmpty || isWorking)
                .buttonStyle(.borderedProminent)

                if KeychainHelper.hasKey(.encryptionKey) && KeychainHelper.canUseBiometry {
                    Button {
                        Task { await unlockWithBiometry() }
                    } label: {
                        Image(systemName: "touchid")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                }
            }

            if isWorking {
                ProgressView("Loading wallets...")
            }
        }
        .task {
            if KeychainHelper.hasKey(.encryptionKey) && KeychainHelper.canUseBiometry {
                while !NSApp.isActive {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                await unlockWithBiometry()
            }
        }
    }

    // MARK: - Actions

    private func checkExistingWallet() {
        if wallet.wallets.isEmpty && KeychainHelper.hasKey(.walletID) {
            // Wallet list was lost (e.g. UserDefaults cleared) but Keychain still has
            // the wallet ID. Reconstruct a placeholder wallet so the unlock flow can
            // load it from the RAILGUN SDK.
            if let walletID = KeychainHelper.load(.walletID) {
                let recovered = Wallet(
                    id: walletID,
                    derivationIndex: 0,
                    railgunAddress: "",
                    name: "Wallet 1"
                )
                wallet.wallets = [recovered]
            }
        }

        if wallet.wallets.isEmpty {
            wallet.setStep(.enterPassword)
        } else {
            wallet.setStep(.unlock)
        }
    }

    private func createWallet() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let mnemonic = try await service.generateMnemonic()
            wallet.mnemonic = mnemonic
            wallet.setStep(.showMnemonic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finalizeWallet() async {
        guard let mnemonic = wallet.mnemonic else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let salt = UUID().uuidString
            let encryptionKey = try await service.deriveEncryptionKey(password: password, salt: salt)
            let creationBlocks = await fetchCreationBlockNumbers()
            let walletInfo = try await service.createWallet(
                encryptionKey: encryptionKey,
                mnemonic: mnemonic,
                derivationIndex: 0,
                creationBlockNumbers: creationBlocks
            )

            try KeychainHelper.save(.walletID, value: walletInfo.id)
            try KeychainHelper.save(.walletSalt, value: salt)
            try? KeychainHelper.save(.encryptionKey, value: encryptionKey)

            let newWallet = Wallet(
                id: walletInfo.id,
                derivationIndex: walletInfo.derivationIndex,
                railgunAddress: walletInfo.railgunAddress,
                name: "Wallet 1"
            )
            let unlocked = Wallet.Unlocked(
                ethAddress: walletInfo.ethAddress,
                ethPrivateKey: walletInfo.ethPrivateKey
            )
            wallet.addWallet(newWallet, unlocked: unlocked)
            wallet.mnemonic = nil
            password = ""
            confirmPassword = ""
            wallet.setStep(.ready)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlockWithBiometry() async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else { return }

        let authenticated = await KeychainHelper.authenticateWithBiometry(
            reason: "Unlock your RAILGUN wallets"
        )
        guard authenticated else { return }

        await loadAllWallets(encryptionKey: encryptionKey)
    }

    private func unlockWallets() async {
        guard let storedSalt = KeychainHelper.load(.walletSalt) else {
            errorMessage = "No wallet found"
            wallet.setStep(.enterPassword)
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let encryptionKey = try await service.deriveEncryptionKey(password: password, salt: storedSalt)
            try? KeychainHelper.save(.encryptionKey, value: encryptionKey)
            await loadAllWallets(encryptionKey: encryptionKey)
            password = ""
        } catch {
            errorMessage = "Failed to unlock: \(error.localizedDescription)"
        }
    }

    /// Load all persisted wallets from the SDK using the encryption key.
    private func loadAllWallets(encryptionKey: String) async {
        isWorking = true
        defer { isWorking = false }

        var unlockedCount = 0
        var failures: [String] = []

        for (index, entry) in wallet.wallets.enumerated() {
            do {
                let walletInfo = try await service.loadWallet(
                    encryptionKey: encryptionKey,
                    walletID: entry.id,
                    derivationIndex: entry.derivationIndex
                )
                // Backfill railgunAddress if it was lost (e.g. recovered from Keychain)
                if entry.railgunAddress.isEmpty {
                    wallet.wallets[index] = Wallet(
                        id: entry.id,
                        derivationIndex: entry.derivationIndex,
                        railgunAddress: walletInfo.railgunAddress,
                        name: entry.name
                    )
                }
                wallet.unlockWallet(entry, with: Wallet.Unlocked(
                    ethAddress: walletInfo.ethAddress,
                    ethPrivateKey: walletInfo.ethPrivateKey
                ))
                unlockedCount += 1
            } catch {
                let detail = "\(entry.name) (\(entry.id.prefix(8))…): \(error.localizedDescription)"
                failures.append(detail)
                AppLogger.shared.log("wallet", "loadWallet failed for \(detail)")
            }
        }

        if unlockedCount == 0 && !wallet.wallets.isEmpty {
            // Every wallet failed — keep the user on the unlock screen with
            // a real error message instead of dropping them into a half-broken
            // ready state where the sidebar lists wallets but every detail
            // page says "Wallet Not Found".
            errorMessage = "Failed to unlock any wallet:\n" + failures.joined(separator: "\n")
            return
        }

        if !failures.isEmpty {
            errorMessage = "Some wallets failed to unlock:\n" + failures.joined(separator: "\n")
        }
        wallet.setStep(.ready)
    }

    /// Fetch current block numbers for all configured chains.
    /// Used as creationBlockNumbers so the SDK skips scanning older blocks.
    private func fetchCreationBlockNumbers() async -> [String: Int] {
        var blocks: [String: Int] = [:]
        for chainName in Chain.allCases.map(\.rawValue) {
            if let blockNumber = try? await service.getBlockNumber(chainName: chainName) {
                blocks[chainName] = blockNumber
            }
        }
        return blocks
    }
}

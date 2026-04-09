//
//  ReplaceCoreMnemonicView.swift
//  railcart
//
//  DEBUG-only: replace the primary mnemonic with a user-supplied one,
//  reset the account list to a single derived wallet, and refresh balances.
//

#if DEBUG

import SwiftUI

struct ReplaceCoreMnemonicView: View {
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(WalletState.self) private var walletState
    @Environment(NetworkState.self) private var network
    @Environment(\.dismiss) private var dismiss

    @State private var mnemonicInput = ""
    @State private var isReplacing = false
    @State private var errorMessage: String?

    private var normalizedMnemonic: String {
        mnemonicInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: /\s+/)
            .joined(separator: " ")
    }

    private var wordCount: Int {
        normalizedMnemonic.isEmpty ? 0 : normalizedMnemonic.split(separator: " ").count
    }

    private var isValidWordCount: Bool {
        [12, 15, 18, 21, 24].contains(wordCount)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Replace Core Mnemonic")
                .font(.title2.bold())

            Text("DEBUG: replaces the primary mnemonic and resets accounts to a single derived wallet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextEditor(text: $mnemonicInput)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textContentType(.none)
                .frame(maxWidth: 400, minHeight: 80, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )

            HStack {
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundStyle(mnemonicInput.isEmpty ? Color.secondary : (isValidWordCount ? Color.green : Color.orange))
                Spacer()
            }
            .frame(maxWidth: 400)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if isReplacing {
                ProgressView("Replacing mnemonic...")
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Replace") {
                    Task { await replace() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidWordCount || isReplacing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 280)
    }

    private func replace() async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            errorMessage = "Wallet must be unlocked first."
            return
        }

        isReplacing = true
        errorMessage = nil
        defer { isReplacing = false }

        let mnemonic = normalizedMnemonic

        do {
            let validation = try await service.validateMnemonic(mnemonic)
            guard validation.valid else {
                errorMessage = validation.error ?? "Invalid recovery phrase."
                return
            }

            // Imported mnemonic may have history — leave creationBlockNumbers empty.
            let walletInfo = try await service.createWallet(
                encryptionKey: encryptionKey,
                mnemonic: mnemonic,
                derivationIndex: 0,
                creationBlockNumbers: [:]
            )

            try KeychainHelper.save(.walletID, value: walletInfo.id)

            let account = Account(
                id: walletInfo.id,
                derivationIndex: walletInfo.derivationIndex,
                railgunAddress: walletInfo.railgunAddress,
                name: "Wallet 1"
            )
            let unlocked = Account.Unlocked(
                ethAddress: walletInfo.ethAddress,
                ethPrivateKey: walletInfo.ethPrivateKey
            )

            walletState.unlockedKeys.removeAll()
            walletState.accounts = [account]
            walletState.unlockedKeys[account.id] = unlocked

            dismiss()

            if let balanceService {
                let chain = network.selectedChain
                try? await network.ensureProviderLoaded(for: chain, using: service)
                await balanceService.scanAllPrivateBalances(
                    chainName: chain.rawValue,
                    walletIDs: [account.id]
                )
            }
        } catch {
            errorMessage = "Replace failed: \(error.localizedDescription)"
        }
    }
}

#endif

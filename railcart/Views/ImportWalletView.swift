//
//  ImportWalletView.swift
//  railcart
//
//  Import an existing wallet from a mnemonic phrase.
//

import SwiftUI

struct ImportWalletView: View {
    @Environment(\.walletService) private var service
    @Environment(WalletState.self) private var walletState
    @Environment(\.dismiss) private var dismiss

    @State private var mnemonicInput = ""
    @State private var derivationIndex = 0
    @State private var showAdvanced = false
    @State private var isImporting = false
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
        wordCount == 12 || wordCount == 24
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Import Wallet")
                .font(.title2.bold())

            Text("Enter your BIP-39 recovery phrase (12 or 24 words).")
                .foregroundStyle(.secondary)

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

            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack {
                    Text("Derivation index:")
                        .font(.body)
                    TextField("0", value: $derivationIndex, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showAdvanced.toggle() }
            }
            .frame(maxWidth: 400)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if isImporting {
                ProgressView("Importing wallet...")
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    Task { await importWallet() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidWordCount || isImporting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 300)
    }

    private func importWallet() async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            errorMessage = "Wallet must be unlocked first."
            return
        }

        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let mnemonic = normalizedMnemonic

        do {
            let validation = try await service.validateMnemonic(mnemonic)
            guard validation.valid else {
                errorMessage = validation.error ?? "Invalid recovery phrase."
                return
            }

            // Imported wallets may have existing history — don't set creation blocks
            let walletInfo = try await service.createWallet(
                encryptionKey: encryptionKey,
                mnemonic: mnemonic,
                derivationIndex: derivationIndex,
                creationBlockNumbers: [:]
            )

            let importCount = walletState.wallets.filter { $0.name.hasPrefix("Imported Wallet") }.count
            let name = importCount == 0 ? "Imported Wallet" : "Imported Wallet \(importCount + 1)"

            let newWallet = Wallet(
                id: walletInfo.id,
                derivationIndex: walletInfo.derivationIndex,
                railgunAddress: walletInfo.railgunAddress,
                name: name
            )
            let unlocked = Wallet.Unlocked(
                ethAddress: walletInfo.ethAddress,
                ethPrivateKey: walletInfo.ethPrivateKey
            )
            walletState.addWallet(newWallet, unlocked: unlocked)
            dismiss()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

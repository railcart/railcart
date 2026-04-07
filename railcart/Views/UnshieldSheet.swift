//
//  UnshieldSheet.swift
//  railcart
//
//  Compact sheet to unshield a base token (private WETH → ETH at any address).
//

import SwiftUI

struct UnshieldSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(NetworkState.self) private var network
    @Environment(TransactionStore.self) private var transactionStore

    let token: Token
    let account: Account
    let unlocked: Account.Unlocked

    @State private var destination = ""
    @State private var amount = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var proofProgress: Double?
    @State private var errorMessage: String?
    @State private var resultTxHash: String?

    private var sendingToSelf: Bool {
        destination.lowercased() == unlocked.ethAddress.lowercased() && !destination.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            Form {
                LabeledContent("From") {
                    Text(account.name).font(.body.bold())
                }
                LabeledContent("Token") {
                    Text(token.symbol).font(.body.bold())
                }
                LabeledContent("Network") {
                    Text(network.selectedChain.displayName)
                }
                Section("Destination") {
                    TextField("0x...", text: $destination)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .disabled(isWorking || resultTxHash != nil)
                    Button("Send to my public address") {
                        destination = unlocked.ethAddress
                    }
                    .controlSize(.small)
                    .disabled(isWorking || resultTxHash != nil)
                }
                Section {
                    TextField("Amount in \(token.symbol)", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking || resultTxHash != nil)
                }
            }
            .formStyle(.grouped)

            if let proofProgress {
                ProgressView(value: proofProgress) {
                    Text(statusMessage ?? "Generating proof...").font(.caption)
                }
            } else if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if let resultTxHash {
                LabeledContent("Sent") {
                    Text(resultTxHash)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button(buttonTitle) {
                    Task { await unshield() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(amount.isEmpty || destination.isEmpty || isWorking || resultTxHash != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var buttonTitle: String {
        if isWorking { return "Unshielding..." }
        if resultTxHash != nil { return "Done" }
        return "Unshield"
    }

    private var header: some View {
        HStack(spacing: 12) {
            TokenIconView(assetName: token.iconAsset)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unshield \(token.symbol)").font(.title3.bold())
                // Curved-back arrow when sending to self, diagonal when sending elsewhere.
                Text(sendingToSelf ? "Private  ↩  Your address" : "Private  ↗  External")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func unshield() async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let ethAmount = Double(amount) else {
            errorMessage = "Invalid amount"
            return
        }
        let weiAmount = String(format: "%.0f", ethAmount * 1e18)

        isWorking = true
        errorMessage = nil
        proofProgress = 0
        statusMessage = "Generating zero-knowledge proof..."

        do {
            let txHash = try await service.unshieldBaseToken(
                chainName: network.selectedChain.rawValue,
                walletID: account.id,
                encryptionKey: encryptionKey,
                toAddress: destination,
                amount: weiAmount,
                privateKey: unlocked.ethPrivateKey,
                onProofProgress: { @Sendable progress in
                    Task { @MainActor in
                        proofProgress = progress
                    }
                }
            )
            resultTxHash = txHash
            statusMessage = nil
            proofProgress = nil
            transactionStore.record(Transaction(
                id: UUID().uuidString,
                action: .unshield,
                chainName: network.selectedChain.rawValue,
                txHash: txHash,
                timestamp: Date(),
                tokenSymbol: token.symbol,
                amount: amount,
                fromAccountID: account.id,
                fromAddress: account.railgunAddress,
                toAddress: destination
            ))
            let chain = network.selectedChain.rawValue
            balanceService?.invalidateEthBalance(chainName: chain, address: destination)
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: account.id)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            proofProgress = nil
        }
        isWorking = false
    }
}

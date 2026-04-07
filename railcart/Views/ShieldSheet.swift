//
//  ShieldSheet.swift
//  railcart
//
//  Compact sheet to shield a base token (ETH → private WETH) from a specific wallet.
//

import SwiftUI

struct ShieldSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(NetworkState.self) private var network
    @Environment(TransactionStore.self) private var transactionStore

    let token: Token
    let account: Account
    let unlocked: Account.Unlocked

    @State private var amount = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var resultTxHash: String?

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
                Section {
                    TextField("Amount in \(token.symbol)", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking || resultTxHash != nil)
                }
            }
            .formStyle(.grouped)

            if let statusMessage {
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
                    Task { await shield() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(amount.isEmpty || isWorking || resultTxHash != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var buttonTitle: String {
        if isWorking { return "Shielding..." }
        if resultTxHash != nil { return "Done" }
        return "Shield"
    }

    private var header: some View {
        HStack(spacing: 12) {
            TokenIconView(assetName: token.iconAsset)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shield \(token.symbol)").font(.title3.bold())
                Text("Public  ↓  Private")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func shield() async {
        let railgunAddress: String
        do {
            railgunAddress = try await service.getRailgunAddress(walletID: account.id)
        } catch {
            errorMessage = "Could not load RAILGUN address."
            return
        }

        guard let ethAmount = Double(amount) else {
            errorMessage = "Invalid amount"
            return
        }
        let weiAmount = String(format: "%.0f", ethAmount * 1e18)

        isWorking = true
        errorMessage = nil
        statusMessage = "Submitting shield transaction..."

        do {
            let txHash = try await service.shieldBaseToken(
                chainName: network.selectedChain.rawValue,
                railgunAddress: railgunAddress,
                amount: weiAmount,
                privateKey: unlocked.ethPrivateKey
            )
            resultTxHash = txHash
            statusMessage = nil
            transactionStore.record(Transaction(
                id: UUID().uuidString,
                action: .shield,
                chainName: network.selectedChain.rawValue,
                txHash: txHash,
                timestamp: Date(),
                tokenSymbol: token.symbol,
                amount: amount,
                fromAccountID: account.id,
                fromAddress: unlocked.ethAddress,
                toAddress: railgunAddress
            ))
            let chain = network.selectedChain.rawValue
            balanceService?.invalidateEthBalance(chainName: chain, address: unlocked.ethAddress)
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: account.id)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isWorking = false
    }
}

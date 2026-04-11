//
//  ShieldSheet.swift
//  railcart
//
//  Sheet to shield a token (ETH or ERC-20) from public to private.
//

import SwiftUI

struct ShieldSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(NetworkState.self) private var network
    @Environment(TransactionStore.self) private var transactionStore

    let token: Token
    let wallet: Wallet
    let unlocked: Wallet.Unlocked

    @State private var amount = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var resultTxHash: String?

    private var isERC20: Bool { token.symbol != "ETH" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            Form {
                LabeledContent("From") {
                    Text(wallet.name).font(.body.bold())
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
                if resultTxHash == nil && !isWorking {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if resultTxHash != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(buttonTitle) {
                        Task { await shield() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(amount.isEmpty || isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var buttonTitle: String {
        isWorking ? "Shielding..." : "Shield"
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
            railgunAddress = try await service.getRailgunAddress(walletID: wallet.id)
        } catch {
            errorMessage = "Could not load RAILGUN address."
            return
        }

        guard let parsedAmount = Decimal(string: amount), parsedAmount > 0 else {
            errorMessage = "Invalid amount"
            return
        }
        let divisor = pow(Decimal(10), token.decimals)
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        let preciseAmount = NSDecimalNumber(decimal: parsedAmount * divisor)
            .rounding(accordingToBehavior: handler).stringValue

        isWorking = true
        errorMessage = nil

        do {
            let txHash: String
            if isERC20 {
                txHash = try await shieldERC20(
                    chainName: network.selectedChain.rawValue,
                    railgunAddress: railgunAddress,
                    amount: preciseAmount
                )
            } else {
                statusMessage = "Submitting shield transaction..."
                txHash = try await service.shieldBaseToken(
                    chainName: network.selectedChain.rawValue,
                    railgunAddress: railgunAddress,
                    amount: preciseAmount,
                    privateKey: unlocked.ethPrivateKey
                )
            }
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
                fromWalletID: wallet.id,
                fromAddress: unlocked.ethAddress,
                toAddress: railgunAddress
            ))
            let chain = network.selectedChain.rawValue
            balanceService?.invalidateEthBalance(chainName: chain, address: unlocked.ethAddress)
            balanceService?.invalidateERC20Balances(chainName: chain, address: unlocked.ethAddress)
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: wallet.id)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isWorking = false
    }

    private func shieldERC20(
        chainName: String,
        railgunAddress: String,
        amount: String
    ) async throws -> String {
        guard let tokenAddress = token.address(on: network.selectedChain) else {
            throw ShieldError.noTokenAddress
        }

        // Step 1: Check allowance
        statusMessage = "Checking token approval..."
        let allowance = try await service.getERC20Allowance(
            chainName: chainName,
            tokenAddress: tokenAddress,
            ownerAddress: unlocked.ethAddress
        )

        let neededAmount = Decimal(string: amount) ?? 0
        let currentAllowance = Decimal(string: allowance) ?? 0

        // Step 2: Approve if needed
        if currentAllowance < neededAmount {
            statusMessage = "Approving \(token.symbol) for shielding..."
            _ = try await service.approveERC20ForShield(
                chainName: chainName,
                tokenAddress: tokenAddress,
                amount: nil, // max approval
                privateKey: unlocked.ethPrivateKey
            )
        }

        // Step 3: Shield
        statusMessage = "Submitting shield transaction..."
        return try await service.shieldERC20(
            chainName: chainName,
            railgunAddress: railgunAddress,
            tokenAddress: tokenAddress,
            amount: amount,
            privateKey: unlocked.ethPrivateKey
        )
    }
}

enum ShieldError: LocalizedError {
    case noTokenAddress

    var errorDescription: String? {
        switch self {
        case .noTokenAddress:
            "This token is not available on the selected network."
        }
    }
}

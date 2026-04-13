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
    /// Public balance of this token in its smallest unit (wei), used for "Max" calculation.
    let publicBalance: String?

    @State private var amount = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var resultTxHash: String?

    private var isERC20: Bool { token.symbol != "ETH" }

    /// Returns (exceedsBalance, maxHuman) if the entered amount + shield fee would exceed the
    /// public balance. For ERC-20s the contract pulls amount * 1.0025 via transferFrom.
    private var exceedsBalance: (maxHuman: String, maxWei: Decimal)? {
        guard isERC20,
              let balStr = publicBalance, let balWei = Decimal(string: balStr), balWei > 0,
              let parsed = Decimal(string: amount), parsed > 0 else { return nil }
        let divisor = pow(Decimal(10), token.decimals)
        let handler = NSDecimalNumberHandler(
            roundingMode: .down, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        let enteredWei = NSDecimalNumber(decimal: parsed * divisor)
            .rounding(accordingToBehavior: handler).decimalValue
        // The contract will try to pull enteredWei * 10025 / 10000
        let totalRequired = NSDecimalNumber(decimal: enteredWei * 10025 / 10000)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .up, scale: 0,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false
            )).decimalValue
        guard totalRequired > balWei else { return nil }
        let maxWei = NSDecimalNumber(decimal: balWei * 10000 / 10025)
            .rounding(accordingToBehavior: handler).decimalValue
        let maxHuman = NSDecimalNumber(decimal: maxWei / divisor).stringValue
        return (maxHuman, maxWei)
    }

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
                    HStack {
                        TextField("Amount in \(token.symbol)", text: $amount)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isWorking || resultTxHash != nil)
                        if publicBalance != nil && resultTxHash == nil && !isWorking {
                            Button("Max") { fillMaxAmount() }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let exceeded = exceedsBalance {
                        Text("Amount + 0.25% shield fee exceeds your balance. Max: \(exceeded.maxHuman) \(token.symbol)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if isERC20 {
                        Text("A 0.25% shield fee is added by the RAILGUN contract.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                    .disabled(amount.isEmpty || isWorking || exceedsBalance != nil)
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

    /// RAILGUN shield fee: 25 basis points (0.25%).
    /// For ERC-20s the contract pulls `amount * 10025 / 10000` via transferFrom,
    /// so the max shieldable amount is `balance * 10000 / 10025`.
    private func fillMaxAmount() {
        guard let balWei = publicBalance, let balInt = Decimal(string: balWei), balInt > 0 else { return }
        let divisor = pow(Decimal(10), token.decimals)
        if isERC20 {
            // max = floor(balance * 10000 / 10025) to leave room for the shield fee
            let handler = NSDecimalNumberHandler(
                roundingMode: .down, scale: 0,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false
            )
            let maxWei = NSDecimalNumber(decimal: balInt * 10000 / 10025)
                .rounding(accordingToBehavior: handler).decimalValue
            let human = maxWei / divisor
            amount = NSDecimalNumber(decimal: human).stringValue
        } else {
            // For ETH the value is sent directly (no transferFrom), so gas is the
            // only concern. Just fill the raw balance and let the user adjust.
            let human = balInt / divisor
            amount = NSDecimalNumber(decimal: human).stringValue
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
            statusMessage = "Waiting for confirmation..."
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
            // Wait for the shield tx to confirm, then refresh balances
            let chain = network.selectedChain.rawValue
            try? await service.waitForTransaction(chainName: chain, txHash: txHash)
            statusMessage = nil
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
            let approveTxHash = try await service.approveERC20ForShield(
                chainName: chainName,
                tokenAddress: tokenAddress,
                amount: nil, // max approval
                privateKey: unlocked.ethPrivateKey
            )
            statusMessage = "Waiting for approval to confirm..."
            try await service.waitForTransaction(chainName: chainName, txHash: approveTxHash)
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

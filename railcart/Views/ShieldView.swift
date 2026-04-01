//
//  ShieldView.swift
//  railcart
//
//  Shield ETH (public → private) on testnet.
//

import SwiftUI

struct ShieldView: View {
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(ShieldState.self) private var shieldState
    @Environment(NetworkState.self) private var network
    @Environment(WalletState.self) private var wallet
    @Environment(TransactionStore.self) private var transactionStore

    @State private var shieldAmount = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var unshieldAmount = ""
    @State private var unshieldToAddress = ""

    private var firstAccount: Account? { wallet.accounts.first }
    private var firstUnlocked: Account.Unlocked? {
        guard let id = firstAccount?.id else { return nil }
        return wallet.unlockedKeys[id]
    }
    private var ethAddress: String { firstUnlocked?.ethAddress ?? "" }
    private var hasEthKey: Bool { firstUnlocked != nil }
    private var hasWallet: Bool { wallet.step == .ready }

    var body: some View {
        @Bindable var shieldState = shieldState
        Form {
            if !hasWallet {
                Section {
                    ContentUnavailableView(
                        "No Wallet",
                        systemImage: "wallet.bifold",
                        description: Text("Create a RAILGUN wallet first in the Wallet tab.")
                    )
                }
            } else {
                ethKeySection
                if hasEthKey {
                    shieldSection
                    unshieldSection
                }
                if let txHash = shieldState.txHash {
                    resultSection("Shield TX", hash: txHash)
                }
                if let unshieldTxHash = shieldState.unshieldTxHash {
                    resultSection("Unshield TX", hash: unshieldTxHash)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 400)
    }

    // MARK: - ETH Key Management

    @ViewBuilder
    private var ethKeySection: some View {
        Section("Ethereum Account") {
            if hasEthKey {
                LabeledContent("Address") {
                    Text(ethAddress)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                LabeledContent("Balance") {
                    HStack {
                        Text(formattedBalance)
                            .font(.body.monospaced())
                        Button("Refresh") {
                            Task { await refreshBalance() }
                        }
                        .controlSize(.mini)
                    }
                }
            } else {
                Text("Create a wallet first to derive your Ethereum address.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formattedBalance: String {
        guard !shieldState.ethBalance.isEmpty, let wei = Double(shieldState.ethBalance) else { return "—" }
        let eth = wei / 1e18
        return String(format: "%.6f ETH", eth)
    }

    // MARK: - Shield

    @ViewBuilder
    private var shieldSection: some View {
        Section("Shield ETH") {
            TextField("Amount in ETH", text: $shieldAmount)
                .textFieldStyle(.roundedBorder)

            Button(isWorking ? "Shielding..." : "Shield ETH") {
                Task { await shieldETH() }
            }
            .disabled(shieldAmount.isEmpty || isWorking)
            .buttonStyle(.borderedProminent)

            if let statusMessage = shieldState.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var unshieldSection: some View {
        Section("Unshield ETH") {
            TextField("Destination address (0x...)", text: $unshieldToAddress)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            TextField("Amount in ETH", text: $unshieldAmount)
                .textFieldStyle(.roundedBorder)

            if let proofProgress = shieldState.proofProgress {
                ProgressView(value: proofProgress) {
                    Text(shieldState.statusMessage ?? "Generating proof...")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }

            Button(isWorking ? "Unshielding..." : "Unshield ETH") {
                Task { await unshieldETH() }
            }
            .disabled(unshieldAmount.isEmpty || unshieldToAddress.isEmpty || isWorking)
            .buttonStyle(.borderedProminent)

            Button("Use my address") {
                unshieldToAddress = ethAddress
            }
            .controlSize(.small)
            .disabled(ethAddress.isEmpty)

            Text("Generates a zero-knowledge proof then sends the unshield transaction from your public wallet (pays gas).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ label: String, hash: String) -> some View {
        Section(label) {
            LabeledContent("TX Hash") {
                Text(hash)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func refreshBalance() async {
        guard !ethAddress.isEmpty, let balanceService else { return }
        do {
            let balance = try await balanceService.getEthBalance(
                chainName: network.selectedChain.rawValue,
                address: ethAddress
            )
            shieldState.ethBalance = balance
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shieldETH() async {
        guard let privateKey = firstUnlocked?.ethPrivateKey,
              let walletID = firstAccount?.id else {
            errorMessage = "Wallet not unlocked"
            return
        }

        let railgunAddress: String
        do {
            railgunAddress = try await service.getRailgunAddress(walletID: walletID)
        } catch {
            errorMessage = "Could not get RAILGUN address. Make sure wallet is loaded."
            return
        }

        guard let ethAmount = Double(shieldAmount) else {
            errorMessage = "Invalid amount"
            return
        }
        let weiAmount = String(format: "%.0f", ethAmount * 1e18)

        isWorking = true
        errorMessage = nil
        shieldState.statusMessage = "Shielding..."

        do {
            let txHash = try await service.shieldBaseToken(
                chainName: network.selectedChain.rawValue,
                railgunAddress: railgunAddress,
                amount: weiAmount,
                privateKey: privateKey
            )

            shieldState.txHash = txHash
            shieldState.statusMessage = "Shield transaction sent"
            transactionStore.record(Transaction(
                id: UUID().uuidString,
                action: .shield,
                chainName: network.selectedChain.rawValue,
                txHash: txHash,
                timestamp: Date(),
                tokenSymbol: "ETH",
                amount: shieldAmount,
                fromAccountID: firstAccount?.id ?? "",
                fromAddress: ethAddress,
                toAddress: railgunAddress
            ))
            // Invalidate both public (ETH spent on gas) and private (new shielded balance)
            let chain = network.selectedChain.rawValue
            balanceService?.invalidateEthBalance(chainName: chain, address: ethAddress)
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: walletID)
            isWorking = false
        } catch {
            errorMessage = error.localizedDescription
            shieldState.statusMessage = nil
            isWorking = false
        }
    }

    private func unshieldETH() async {
        guard let privateKey = firstUnlocked?.ethPrivateKey,
              let walletID = firstAccount?.id,
              let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }

        guard let ethAmount = Double(unshieldAmount) else {
            errorMessage = "Invalid amount"
            return
        }
        let weiAmount = String(format: "%.0f", ethAmount * 1e18)

        isWorking = true
        errorMessage = nil
        shieldState.proofProgress = 0
        shieldState.statusMessage = "Generating zero-knowledge proof..."

        do {
            let txHash = try await service.unshieldBaseToken(
                chainName: network.selectedChain.rawValue,
                walletID: walletID,
                encryptionKey: encryptionKey,
                toAddress: unshieldToAddress,
                amount: weiAmount,
                privateKey: privateKey,
                onProofProgress: { @Sendable progress in
                    Task { @MainActor in
                        shieldState.proofProgress = progress
                    }
                }
            )

            shieldState.unshieldTxHash = txHash
            shieldState.statusMessage = nil
            shieldState.proofProgress = nil
            transactionStore.record(Transaction(
                id: UUID().uuidString,
                action: .unshield,
                chainName: network.selectedChain.rawValue,
                txHash: txHash,
                timestamp: Date(),
                tokenSymbol: "ETH",
                amount: unshieldAmount,
                fromAccountID: firstAccount?.id ?? "",
                fromAddress: firstAccount?.railgunAddress ?? "",
                toAddress: unshieldToAddress
            ))
            // Invalidate both public (ETH received) and private (spent shielded balance)
            let chain = network.selectedChain.rawValue
            balanceService?.invalidateEthBalance(chainName: chain, address: unshieldToAddress)
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: walletID)
            isWorking = false
        } catch {
            errorMessage = error.localizedDescription
            shieldState.statusMessage = nil
            shieldState.proofProgress = nil
            isWorking = false
        }
    }
}

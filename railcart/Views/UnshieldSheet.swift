//
//  UnshieldSheet.swift
//  railcart
//
//  Compact sheet to unshield a base token (private WETH → ETH at any address).
//  Supports direct unshield (user pays gas) or broadcaster-mediated (no gas needed).
//

import SwiftUI

struct UnshieldSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(NodeBridge.self) private var bridge
    @Environment(NetworkState.self) private var network
    @Environment(TransactionStore.self) private var transactionStore

    let token: Token
    let wallet: Wallet
    let unlocked: Wallet.Unlocked

    enum Method: String, CaseIterable {
        case direct = "Direct"
        case broadcaster = "Via Broadcaster"
    }

    @State private var method: Method = .direct
    @State private var destination = ""
    @State private var amount = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var proofProgress: Double?
    @State private var errorMessage: String?
    @State private var resultTxHash: String?

    // Broadcaster-specific state
    @State private var broadcasterPhase: BroadcasterPhase = .idle
    @State private var broadcasters: [BroadcasterInfo] = []
    @State private var feeEstimate: BroadcasterFeeEstimate?
    @State private var currentStep: BroadcasterUnshieldStep?
    @State private var completedSteps: Set<String> = []

    enum BroadcasterPhase {
        case idle
        case loadingBroadcasters
        case selectBroadcaster
        case executing
    }

    private var sendingToSelf: Bool {
        destination.lowercased() == unlocked.ethAddress.lowercased() && !destination.isEmpty
    }

    private var inputsLocked: Bool {
        isWorking || resultTxHash != nil || broadcasterPhase == .executing
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

                Picker("Method", selection: $method) {
                    ForEach(Method.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(inputsLocked)

                if method == .direct {
                    Text("You pay gas from your public ETH balance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("A broadcaster pays gas. A small fee is deducted from your private balance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Destination") {
                    TextField("0x...", text: $destination)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .disabled(inputsLocked)
                    Button("Send to my public address") {
                        destination = unlocked.ethAddress
                    }
                    .controlSize(.small)
                    .disabled(inputsLocked)
                }
                Section {
                    TextField("Amount in \(token.symbol)", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .disabled(inputsLocked)
                }
            }
            .formStyle(.grouped)

            // Status area
            switch method {
            case .direct:
                directStatusArea
            case .broadcaster:
                broadcasterStatusArea
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

            // Action buttons
            HStack {
                if resultTxHash == nil && !isWorking && broadcasterPhase != .executing {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if resultTxHash != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if method == .direct {
                    Button(isWorking ? "Unshielding..." : "Unshield") {
                        Task { await directUnshield() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(amount.isEmpty || destination.isEmpty || isWorking)
                } else {
                    broadcasterActionButton
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            TokenIconView(assetName: token.iconAsset)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unshield \(token.symbol)").font(.title3.bold())
                Text(sendingToSelf ? "Private  ↩  Your address" : "Private  ↗  External")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Direct Status

    @ViewBuilder
    private var directStatusArea: some View {
        if let proofProgress {
            ProgressView(value: proofProgress) {
                Text(statusMessage ?? "Generating proof...").font(.caption)
            }
        } else if let statusMessage {
            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Broadcaster Status

    @ViewBuilder
    private var broadcasterStatusArea: some View {
        switch broadcasterPhase {
        case .idle:
            EmptyView()
        case .loadingBroadcasters:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding broadcasters...").font(.caption).foregroundStyle(.secondary)
            }
        case .selectBroadcaster:
            broadcasterList
        case .executing:
            broadcasterStepList
        }
    }

    private var broadcasterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if broadcasters.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                    Text("No broadcasters available").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Select a broadcaster").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(broadcasters, id: \.feesID) { broadcaster in
                            Button {
                                Task { await selectBroadcaster(broadcaster) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(broadcaster.shortRailgunAddress)
                                            .font(.caption2.monospaced())
                                        Label(String(format: "%.0f%%", broadcaster.reliability * 100),
                                              systemImage: "chart.bar.fill")
                                            .font(.caption2)
                                            .foregroundStyle(broadcaster.reliability > 0.8 ? .green : .orange)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Fee: \(formattedFee(for: broadcaster))")
                                            .font(.caption2.monospaced())
                                        Text(token.symbol).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(broadcaster.isExpired)
                            .opacity(broadcaster.isExpired ? 0.5 : 1)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private var broadcasterStepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepRow(.generatingProof, "Generating zero-knowledge proof")
            if currentStep == .generatingProof, let proofProgress {
                ProgressView(value: proofProgress).padding(.leading, 28)
            }
            stepRow(.populatingTransaction, "Populating transaction")
            stepRow(.submittingToBroadcaster, "Submitting to broadcaster")
        }
    }

    private func stepRow(_ step: BroadcasterUnshieldStep, _ label: String) -> some View {
        let key = "\(step)"
        let done = completedSteps.contains(key)
        let active = currentStep == step
        return HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if active {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "circle").foregroundStyle(.quaternary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(done ? .secondary : active ? .primary : .quaternary)
        }
    }

    // MARK: - Broadcaster Action Button

    @ViewBuilder
    private var broadcasterActionButton: some View {
        switch broadcasterPhase {
        case .idle:
            Button("Find Broadcasters") {
                Task { await loadBroadcasters() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(amount.isEmpty || destination.isEmpty)
        case .loadingBroadcasters:
            Button("Finding...") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .selectBroadcaster:
            Button("Find Broadcasters") {
                Task { await loadBroadcasters() }
            }
            .buttonStyle(.bordered)
            .disabled(amount.isEmpty || destination.isEmpty)
        case .executing:
            Button("Submitting...") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }

    // MARK: - Direct Unshield

    private func directUnshield() async {
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
                walletID: wallet.id,
                encryptionKey: encryptionKey,
                toAddress: destination,
                amount: weiAmount,
                privateKey: unlocked.ethPrivateKey,
                onProofProgress: { @Sendable progress in
                    Task { @MainActor in proofProgress = progress }
                }
            )
            finishWithTxHash(txHash)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            proofProgress = nil
        }
        isWorking = false
    }

    // MARK: - Broadcaster Unshield

    private func loadBroadcasters() async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let ethAmount = Double(amount) else {
            errorMessage = "Invalid amount"
            return
        }
        let weiAmount = String(format: "%.0f", ethAmount * 1e18)
        guard let wrappedAddress = token.address(on: network.selectedChain) else {
            errorMessage = "Token not supported on this chain"
            return
        }

        broadcasterPhase = .loadingBroadcasters
        errorMessage = nil

        do {
            let _ = try await bridge.callRaw("startBroadcasterSearch", params: [
                "chainName": network.selectedChain.rawValue,
            ])

            let listResult = try await bridge.call("getBroadcastersForToken", params: [
                "tokenAddress": wrappedAddress,
                "useRelayAdapt": true,
            ], as: BroadcasterListResponse.self)

            let available = listResult.broadcasters.filter { !$0.isExpired }

            if let best = available.sorted(by: { $0.reliability > $1.reliability }).first {
                feeEstimate = try await service.estimateBroadcasterFee(
                    chainName: network.selectedChain.rawValue,
                    walletID: wallet.id,
                    encryptionKey: encryptionKey,
                    toAddress: destination,
                    amount: weiAmount,
                    feePerUnitGas: best.feePerUnitGas
                )
            }

            broadcasters = available.sorted(by: { $0.reliability > $1.reliability })
            broadcasterPhase = .selectBroadcaster
        } catch {
            errorMessage = error.localizedDescription
            broadcasterPhase = .idle
        }
    }

    private func selectBroadcaster(_ broadcaster: BroadcasterInfo) async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let ethAmount = Double(amount) else {
            errorMessage = "Invalid amount"
            return
        }
        let weiAmount = String(format: "%.0f", ethAmount * 1e18)

        let estimate: BroadcasterFeeEstimate
        if let existing = feeEstimate,
           let gasEst = Decimal(string: existing.gasEstimate),
           let feeRate = Decimal(string: broadcaster.feePerUnitGas) {
            let fee = gasEst * feeRate
            estimate = BroadcasterFeeEstimate(
                gasEstimate: existing.gasEstimate,
                broadcasterFeeAmount: "\(fee)",
                gasPrice: existing.gasPrice
            )
        } else {
            do {
                estimate = try await service.estimateBroadcasterFee(
                    chainName: network.selectedChain.rawValue,
                    walletID: wallet.id,
                    encryptionKey: encryptionKey,
                    toAddress: destination,
                    amount: weiAmount,
                    feePerUnitGas: broadcaster.feePerUnitGas
                )
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        broadcasterPhase = .executing
        errorMessage = nil

        do {
            let txHash = try await service.unshieldBaseTokenViaBroadcaster(
                chainName: network.selectedChain.rawValue,
                walletID: wallet.id,
                encryptionKey: encryptionKey,
                toAddress: destination,
                amount: weiAmount,
                broadcaster: broadcaster,
                feeEstimate: estimate,
                onStep: { @Sendable step in
                    Task { @MainActor in
                        if let prev = currentStep { completedSteps.insert("\(prev)") }
                        currentStep = step
                        if step != .generatingProof { proofProgress = nil }
                    }
                },
                onProofProgress: { @Sendable progress in
                    Task { @MainActor in proofProgress = progress }
                }
            )
            if let prev = currentStep { completedSteps.insert("\(prev)") }
            finishWithTxHash(txHash)
        } catch {
            errorMessage = error.localizedDescription
            broadcasterPhase = .idle
            currentStep = nil
            completedSteps = []
            proofProgress = nil
        }
    }

    // MARK: - Helpers

    private func finishWithTxHash(_ txHash: String) {
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
            fromWalletID: wallet.id,
            fromAddress: wallet.railgunAddress,
            toAddress: destination
        ))
        let chain = network.selectedChain.rawValue
        balanceService?.invalidateEthBalance(chainName: chain, address: destination)
        balanceService?.invalidatePrivateBalances(chainName: chain, walletID: wallet.id)
    }

    private func formattedFee(for broadcaster: BroadcasterInfo) -> String {
        guard let gasEst = Decimal(string: feeEstimate?.gasEstimate ?? "0"),
              let feeRate = Decimal(string: broadcaster.feePerUnitGas) else {
            return "..."
        }
        let feeWei = gasEst * feeRate
        return token.formatBalance("\(feeWei)")
    }
}

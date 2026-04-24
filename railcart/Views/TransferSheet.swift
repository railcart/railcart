//
//  TransferSheet.swift
//  railcart
//
//  Sheet to send a shielded token from one 0zk address to another (zk → zk).
//  Supports direct (self-signed) or broadcaster-mediated submission.
//

import BigInt
import SwiftUI

struct TransferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(\.keychain) private var keychain
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

    @State private var method: Method = .broadcaster
    @State private var destination = ""
    @State private var amount = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var proofProgress: Double?
    @State private var errorMessage: String?
    @State private var resultTxHash: String?

    /// Nil while unchecked, true/false after validation.
    @State private var destinationIsValid: Bool?
    @State private var destinationValidationTask: Task<Void, Never>?

    // Broadcaster-specific state
    @State private var broadcasterPhase: BroadcasterPhase = .idle
    @State private var broadcasters: [BroadcasterInfo] = []
    @State private var feeEstimate: BroadcasterFeeEstimate?
    @State private var currentStep: BroadcasterUnshieldStep?
    @State private var completedSteps: Set<String> = []
    @State private var resolvedFeeTokenAddress: String?
    @State private var broadcasterPollTask: Task<Void, Never>?
    @State private var broadcasterSearchStarted: Date?

    enum BroadcasterPhase {
        case idle
        case loadingBroadcasters
        case selectBroadcaster
        case executing
    }

    private var isERC20: Bool { token.symbol != "ETH" }

    private var sendingToSelf: Bool {
        destination.trimmingCharacters(in: .whitespacesAndNewlines) == wallet.railgunAddress
    }

    private var destinationError: String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if sendingToSelf { return "Cannot send to yourself" }
        if destinationIsValid == false { return "Not a valid 0zk address" }
        return nil
    }

    private var canSubmit: Bool {
        !amount.isEmpty
            && !destination.isEmpty
            && destinationIsValid == true
            && !sendingToSelf
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
                    Text("You pay gas from your public ETH balance. Your public signer address will appear on-chain alongside a RAILGUN transaction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("A broadcaster pays gas in exchange for a small private fee. Recommended for maximum privacy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Recipient 0zk Address") {
                    TextField("0zk1q...", text: $destination)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .disabled(inputsLocked)
                        .onChange(of: destination) { scheduleDestinationValidation() }
                    if let error = destinationError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Amount in \(token.symbol)", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .disabled(inputsLocked)
                }
            }
            .formStyle(.grouped)

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
                    Button(isWorking ? "Sending..." : "Send") {
                        Task { await directTransfer() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || isWorking)
                } else {
                    broadcasterActionButton
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .onDisappear {
            destinationValidationTask?.cancel()
            broadcasterPollTask?.cancel()
            Task { try? await bridge.callRaw("stopBroadcasterSearch") }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TokenIconView(assetName: token.iconAsset)
            VStack(alignment: .leading, spacing: 2) {
                Text("Send \(token.symbol)").font(.title3.bold())
                Text("Private  →  Private")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

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

    @ViewBuilder
    private var broadcasterStatusArea: some View {
        switch broadcasterPhase {
        case .idle:
            EmptyView()
        case .loadingBroadcasters:
            EmptyView()
        case .selectBroadcaster:
            broadcasterList
        case .executing:
            if currentStep == nil, let statusMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                broadcasterStepList
            }
        }
    }

    private var isStillSearching: Bool {
        guard broadcasters.isEmpty,
              let started = broadcasterSearchStarted else { return false }
        return Date().timeIntervalSince(started) < 20
    }

    private var broadcasterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if broadcasters.isEmpty && isStillSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for broadcasters...").font(.caption).foregroundStyle(.secondary)
                }
            } else if broadcasters.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                    Text("No broadcasters available").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select a broadcaster").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text("Fee is deducted from your private \(token.symbol) balance")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
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
                                        Text("\(formattedFee()) \(token.symbol)")
                                            .font(.caption2.monospaced())
                                        Text("fee").font(.caption2).foregroundStyle(.tertiary)
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

    @ViewBuilder
    private var broadcasterActionButton: some View {
        switch broadcasterPhase {
        case .idle:
            Button("Find Broadcasters") {
                Task { await loadBroadcasters() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        case .loadingBroadcasters:
            Button("Finding...") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .selectBroadcaster:
            Button("Find Broadcasters") {
                Task { await loadBroadcasters() }
            }
            .buttonStyle(.bordered)
            .disabled(!canSubmit)
        case .executing:
            Button("Submitting...") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }

    // MARK: - Validation

    private func scheduleDestinationValidation() {
        destinationValidationTask?.cancel()
        destinationIsValid = nil
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        destinationValidationTask = Task { [service] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let valid = (try? await service.validateRailgunAddress(trimmed)) ?? false
            if Task.isCancelled { return }
            await MainActor.run {
                if destination.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    destinationIsValid = valid
                }
            }
        }
    }

    // MARK: - Direct Transfer

    private func directTransfer() async {
        guard let encryptionKey = keychain.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let weiAmount = parseAmountToWei() else {
            errorMessage = "Invalid amount"
            return
        }

        guard let tokenAddress = resolveTokenAddress() else {
            errorMessage = "Token not supported on this chain"
            return
        }

        isWorking = true
        errorMessage = nil
        proofProgress = 0
        statusMessage = "Generating zero-knowledge proof..."

        guard let nativeScanner = balanceService?.nativeScanner else {
            errorMessage = "Scanner not available"
            isWorking = false
            return
        }

        do {
            let txHash = try await service.transferPrivate(
                chainName: network.selectedChain.rawValue,
                walletID: wallet.id,
                encryptionKey: encryptionKey,
                recipientRailgunAddress: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                tokenAddress: tokenAddress,
                amount: weiAmount,
                privateKey: unlocked.ethPrivateKey,
                nativeScanner: nativeScanner,
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

    // MARK: - Broadcaster Transfer

    private func loadBroadcasters() async {
        guard keychain.load(.encryptionKey) != nil else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard parseAmountToWei() != nil else {
            errorMessage = "Invalid amount"
            return
        }
        guard let feeTokenAddress = resolveTokenAddress() else {
            errorMessage = "Token not supported on this chain"
            return
        }

        broadcasterPhase = .loadingBroadcasters
        broadcasterSearchStarted = Date()
        errorMessage = nil

        do {
            let _ = try await bridge.callRaw("startBroadcasterSearch", params: [
                "chainName": network.selectedChain.rawValue,
            ])
        } catch {
            errorMessage = error.localizedDescription
            broadcasterPhase = .idle
            return
        }

        broadcasterPollTask?.cancel()
        broadcasterPollTask = Task {
            let chain = network.selectedChain
            let activeFeeToken = feeTokenAddress
            while !Task.isCancelled {
                do {
                    let result = try await bridge.call("getBroadcastersForToken", params: [
                        "tokenAddress": activeFeeToken,
                        "useRelayAdapt": true,
                    ], as: BroadcasterListResponse.self)

                    let available = result.broadcasters
                        .filter { !$0.isExpired }
                        .sorted { $0.reliability > $1.reliability }

                    var newEstimate = feeEstimate
                    if let best = available.first {
                        newEstimate = try? await service.estimateBroadcasterFeeTransfer(
                            chainName: chain.rawValue,
                            tokenAddress: activeFeeToken,
                            feePerUnitGas: best.feePerUnitGas
                        )
                    }

                    broadcasters = available
                    resolvedFeeTokenAddress = activeFeeToken
                    if let newEstimate { feeEstimate = newEstimate }
                    if broadcasterPhase == .loadingBroadcasters {
                        broadcasterPhase = .selectBroadcaster
                    }
                } catch {
                    // Don't fail the whole flow on a single poll error.
                }

                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func selectBroadcaster(_ broadcaster: BroadcasterInfo) async {
        guard let encryptionKey = keychain.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let weiAmount = parseAmountToWei() else {
            errorMessage = "Invalid amount"
            return
        }
        guard let tokenAddress = resolveTokenAddress(),
              let feeAddr = resolvedFeeTokenAddress else {
            errorMessage = "Token not supported on this chain"
            return
        }
        let recipient = destination.trimmingCharacters(in: .whitespacesAndNewlines)

        let estimate: BroadcasterFeeEstimate
        do {
            estimate = try await service.estimateBroadcasterFeeTransfer(
                chainName: network.selectedChain.rawValue,
                tokenAddress: feeAddr,
                feePerUnitGas: broadcaster.feePerUnitGas
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        broadcasterPollTask?.cancel()
        broadcasterPhase = .executing
        errorMessage = nil

        let progressHandler: @Sendable (BroadcasterUnshieldStep) -> Void = { @Sendable step in
            Task { @MainActor in
                if let prev = currentStep { completedSteps.insert("\(prev)") }
                currentStep = step
                if step != .generatingProof { proofProgress = nil }
            }
        }
        let proofHandler: @Sendable (Double) -> Void = { @Sendable progress in
            Task { @MainActor in proofProgress = progress }
        }

        guard let nativeScanner = balanceService?.nativeScanner else {
            errorMessage = "Scanner not available"
            broadcasterPhase = .idle
            return
        }

        do {
            let txHash = try await service.transferPrivateViaBroadcaster(
                chainName: network.selectedChain.rawValue,
                walletID: wallet.id,
                encryptionKey: encryptionKey,
                recipientRailgunAddress: recipient,
                tokenAddress: tokenAddress,
                amount: weiAmount,
                broadcaster: broadcaster,
                feeEstimate: estimate,
                feeTokenAddress: feeAddr,
                nativeScanner: nativeScanner,
                onStep: progressHandler,
                onProofProgress: proofHandler
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

    private func resolveTokenAddress() -> String? {
        if isERC20 {
            return token.address(on: network.selectedChain)
        }
        // Base token (ETH) is represented as WETH in the private balance.
        return Token.weth.address(on: network.selectedChain)
    }

    private func parseAmountToWei() -> String? {
        guard let parsed = Decimal(string: amount), parsed > 0 else { return nil }
        let divisor = pow(Decimal(10), token.decimals)
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: parsed * divisor)
            .rounding(accordingToBehavior: handler).stringValue
    }

    private func finishWithTxHash(_ txHash: String) {
        resultTxHash = txHash
        statusMessage = "Waiting for confirmation..."
        proofProgress = nil
        let recipient = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        transactionStore.record(Transaction(
            id: UUID().uuidString,
            action: .privateSend,
            chainName: network.selectedChain.rawValue,
            txHash: txHash,
            timestamp: Date(),
            tokenSymbol: token.symbol,
            amount: amount,
            fromWalletID: wallet.id,
            fromAddress: wallet.railgunAddress,
            toAddress: recipient
        ))
        let chain = network.selectedChain.rawValue
        let tokenAddress = token.address(on: network.selectedChain) ?? ""
        balanceService?.markTokenStale(chainName: chain, walletID: wallet.id, tokenAddress: tokenAddress)
        Task {
            try? await service.waitForTransaction(chainName: chain, txHash: txHash)
            statusMessage = nil
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: wallet.id)
            try? await Task.sleep(for: .seconds(15))
            await balanceService?.scanAllPrivateBalances(chainName: chain, wallets: [wallet])
            balanceService?.clearStale(chainName: chain, walletID: wallet.id, tokenAddress: tokenAddress)
        }
    }

    private func formattedFee() -> String {
        guard let baseFee = BigUInt(feeEstimate?.broadcasterFeeAmount ?? "0"),
              baseFee > 0 else {
            return "..."
        }
        return token.formatBalance(String(baseFee))
    }
}

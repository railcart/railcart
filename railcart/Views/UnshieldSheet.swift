//
//  UnshieldSheet.swift
//  railcart
//
//  Sheet to unshield a token (private → public at any address).
//  Supports base token (WETH → ETH) and ERC-20 tokens.
//  Supports direct unshield (user pays gas) or broadcaster-mediated (no gas needed).
//

import BigInt
import SwiftUI

struct UnshieldSheet: View {
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
    /// The token address used for broadcaster fees (may differ from the unshielded token
    /// if no broadcasters support that token and we fell back to WETH).
    @State private var resolvedFeeTokenAddress: String?
    /// Background task that continuously polls for broadcaster updates.
    @State private var broadcasterPollTask: Task<Void, Never>?
    /// When the broadcaster search started, so we show "searching" for at least 20s.
    @State private var broadcasterSearchStarted: Date?

    enum BroadcasterPhase {
        case idle
        case loadingBroadcasters
        case selectBroadcaster
        case executing
    }

    /// True for ERC-20 tokens; false for ETH (base token, uses WETH unwrap path).
    private var isERC20: Bool { token.symbol != "ETH" }

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
        .onDisappear {
            broadcasterPollTask?.cancel()
            Task { try? await bridge.callRaw("stopBroadcasterSearch") }
        }
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
                                        Text("\(formattedFee(for: broadcaster)) \(token.symbol)")
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
        guard let encryptionKey = keychain.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let weiAmount = parseAmountToWei() else {
            errorMessage = "Invalid amount"
            return
        }

        // Resolve token address (WETH for base token, ERC20 address otherwise)
        let tokenAddress: String
        if isERC20 {
            guard let addr = token.address(on: network.selectedChain) else {
                errorMessage = "Token not supported on this chain"
                return
            }
            tokenAddress = addr
        } else {
            guard let wethAddr = Token.weth.address(on: network.selectedChain) else {
                errorMessage = "Token not supported on this chain"
                return
            }
            tokenAddress = wethAddr
        }

        isWorking = true
        errorMessage = nil
        proofProgress = 0
        statusMessage = "Generating zero-knowledge proof..."

        guard let nativeScanner = balanceService?.nativeScanner,
              let liveService = service as? LiveWalletService else {
            errorMessage = "Scanner not available"
            isWorking = false
            return
        }

        do {
            let txHash = try await liveService.unshieldWithNativeScanner(
                chainName: network.selectedChain.rawValue,
                walletID: wallet.id,
                encryptionKey: encryptionKey,
                toAddress: destination,
                tokenAddress: tokenAddress,
                amount: weiAmount,
                privateKey: unlocked.ethPrivateKey,
                nativeScanner: nativeScanner,
                onProofProgress: { @Sendable progress in
                    Task { @MainActor in proofProgress = progress }
                },
                onStatusUpdate: { @Sendable status in
                    Task { @MainActor in statusMessage = status }
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
        guard let encryptionKey = keychain.load(.encryptionKey) else {
            errorMessage = "Wallet not unlocked"
            return
        }
        guard let weiAmount = parseAmountToWei() else {
            errorMessage = "Invalid amount"
            return
        }

        // Look up broadcasters by the token being unshielded — broadcasters
        // advertise which tokens they accept fees in.
        let feeTokenAddress: String
        if isERC20 {
            guard let addr = token.address(on: network.selectedChain) else {
                errorMessage = "Token not supported on this chain"
                return
            }
            feeTokenAddress = addr
        } else {
            guard let wethAddr = Token.weth.address(on: network.selectedChain) else {
                errorMessage = "Token not supported on this chain"
                return
            }
            feeTokenAddress = wethAddr
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

        // Start continuous polling — broadcaster fees arrive async over Waku P2P
        // and expire, so we keep refreshing as long as the sheet is open.
        broadcasterPollTask?.cancel()
        broadcasterPollTask = Task {
            let chain = network.selectedChain
            var activeFeeToken = feeTokenAddress
            while !Task.isCancelled {
                do {
                    var result = try await bridge.call("getBroadcastersForToken", params: [
                        "tokenAddress": activeFeeToken,
                        "useRelayAdapt": true,
                    ], as: BroadcasterListResponse.self)

                    // Cross-token broadcaster fees (e.g. pay WETH for a USDC unshield)
                    // are not supported by the native proof path. Don't fall back to WETH.

                    let available = result.broadcasters
                        .filter { !$0.isExpired }
                        .sorted { $0.reliability > $1.reliability }

                    // Update fee estimate if we have broadcasters and inputs
                    var newEstimate = feeEstimate
                    if let best = available.first, let wei = parseAmountToWei() {
                        if isERC20, let tokenAddr = token.address(on: chain) {
                            newEstimate = try? await service.estimateBroadcasterFeeERC20(
                                chainName: chain.rawValue,
                                walletID: wallet.id,
                                encryptionKey: encryptionKey,
                                toAddress: destination,
                                tokenAddress: tokenAddr,
                                amount: wei,
                                feePerUnitGas: best.feePerUnitGas,
                                feeTokenAddress: activeFeeToken
                            )
                        } else {
                            newEstimate = try? await service.estimateBroadcasterFee(
                                chainName: chain.rawValue,
                                walletID: wallet.id,
                                encryptionKey: encryptionKey,
                                toAddress: destination,
                                amount: wei,
                                feePerUnitGas: best.feePerUnitGas
                            )
                        }
                    }

                    broadcasters = available
                    resolvedFeeTokenAddress = activeFeeToken
                    if let newEstimate { feeEstimate = newEstimate }
                    if broadcasterPhase == .loadingBroadcasters && !available.isEmpty {
                        broadcasterPhase = .selectBroadcaster
                    } else if broadcasterPhase == .loadingBroadcasters {
                        // Show the empty list so the user knows we're looking
                        broadcasterPhase = .selectBroadcaster
                    }
                } catch {
                    // Don't fail the whole flow on a single poll error
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

        // Always fetch a fresh fee estimate for the selected broadcaster
        let estimate: BroadcasterFeeEstimate
        do {
            if isERC20 {
                guard let tokenAddress = token.address(on: network.selectedChain),
                      let feeAddr = resolvedFeeTokenAddress else {
                    errorMessage = "Token not supported on this chain"
                    return
                }
                estimate = try await service.estimateBroadcasterFeeERC20(
                    chainName: network.selectedChain.rawValue,
                    walletID: wallet.id,
                    encryptionKey: encryptionKey,
                    toAddress: destination,
                    tokenAddress: tokenAddress,
                    amount: weiAmount,
                    feePerUnitGas: broadcaster.feePerUnitGas,
                    feeTokenAddress: feeAddr
                )
            } else {
                estimate = try await service.estimateBroadcasterFee(
                    chainName: network.selectedChain.rawValue,
                    walletID: wallet.id,
                    encryptionKey: encryptionKey,
                    toAddress: destination,
                    amount: weiAmount,
                    feePerUnitGas: broadcaster.feePerUnitGas
                )
            }
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

        do {
            let txHash: String
            if isERC20 {
                guard let tokenAddress = token.address(on: network.selectedChain),
                      let feeAddr = resolvedFeeTokenAddress else {
                    errorMessage = "Token not supported on this chain"
                    broadcasterPhase = .idle
                    return
                }
                guard let nativeScanner = balanceService?.nativeScanner,
                      let liveService = service as? LiveWalletService else {
                    errorMessage = "Scanner not available"
                    broadcasterPhase = .idle
                    return
                }
                txHash = try await liveService.unshieldERC20ViaBroadcaster(
                    chainName: network.selectedChain.rawValue,
                    walletID: wallet.id,
                    encryptionKey: encryptionKey,
                    toAddress: destination,
                    tokenAddress: tokenAddress,
                    amount: weiAmount,
                    broadcaster: broadcaster,
                    feeEstimate: estimate,
                    feeTokenAddress: feeAddr,
                    nativeScanner: nativeScanner,
                    onStep: progressHandler,
                    onProofProgress: proofHandler
                )
            } else {
                txHash = try await service.unshieldBaseTokenViaBroadcaster(
                    chainName: network.selectedChain.rawValue,
                    walletID: wallet.id,
                    encryptionKey: encryptionKey,
                    toAddress: destination,
                    amount: weiAmount,
                    broadcaster: broadcaster,
                    feeEstimate: estimate,
                    onStep: progressHandler,
                    onProofProgress: proofHandler
                )
            }
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

    /// Convert the user-entered amount to the token's smallest unit (wei).
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
        let tokenAddress = token.address(on: network.selectedChain) ?? ""
        balanceService?.markTokenStale(chainName: chain, walletID: wallet.id, tokenAddress: tokenAddress)
        Task {
            try? await service.waitForTransaction(chainName: chain, txHash: txHash)
            statusMessage = nil
            balanceService?.invalidateEthBalance(chainName: chain, address: destination)
            balanceService?.invalidateERC20Balances(chainName: chain, address: destination)
            balanceService?.invalidatePrivateBalances(chainName: chain, walletID: wallet.id)
            // Wait for the subgraph to index the confirmed block before rescanning
            try? await Task.sleep(for: .seconds(15))
            await balanceService?.scanAllPrivateBalances(chainName: chain, wallets: [wallet])
            balanceService?.clearStale(chainName: chain, walletID: wallet.id, tokenAddress: tokenAddress)
        }
    }

    private func formattedFee(for broadcaster: BroadcasterInfo) -> String {
        // Use the stored broadcasterFeeAmount from the estimate (computed by the bridge
        // using the SDK formula: tokenFee = feePerUnitGas * gasLimit * gasPrice / 10^18).
        // Scale it by the ratio of this broadcaster's rate to the estimate's rate.
        guard let baseFee = BigUInt(feeEstimate?.broadcasterFeeAmount ?? "0"),
              baseFee > 0 else {
            return "..."
        }
        // The estimate was computed for the "best" broadcaster. For other broadcasters,
        // the fee scales linearly with feePerUnitGas.
        return token.formatBalance(String(baseFee))
    }
}

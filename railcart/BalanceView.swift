//
//  BalanceView.swift
//  railcart
//
//  Display private RAILGUN token balances.
//

import SwiftUI

struct BalanceView: View {
    @Environment(\.balanceService) private var balanceService
    @Environment(NodeBridge.self) private var bridge  // for scan progress events
    @Environment(BalanceState.self) private var balanceState
    @Environment(NetworkState.self) private var network

    @State private var isScanning = false
    @State private var scanStep: String?
    @State private var scanProgress: Double = 0
    @State private var scanPassCount: Int = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var hasWallet: Bool { KeychainHelper.hasKey(.walletID) }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if !hasWallet {
                ContentUnavailableView(
                    "No Wallet",
                    systemImage: "wallet.bifold",
                    description: Text("Create a RAILGUN wallet first.")
                )
            } else if isScanning {
                scanProgressView
            } else if balanceState.balances.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Balances",
                    systemImage: "tray",
                    description: Text("Shield some tokens to see private balances here.")
                )
            } else {
                balanceListView
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding()
            }
        }
        .frame(minWidth: 450, minHeight: 300)
        .task { listenForScanEvents() }
    }

    private var headerView: some View {
        HStack {
            Text("Private Balances")
                .font(.title2.bold())
            Spacer()

            Button("Refresh") {
                Task { await loadBalances() }
            }
            .disabled(isLoading || !hasWallet)
            .controlSize(.small)
        }
        .padding()
    }

    private var scanProgressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: scanProgress) {
                Text(scanStep ?? "Scanning...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } currentValueLabel: {
                Text("\(Int(scanProgress * 100))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 300)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    private var balanceListView: some View {
        List(balanceState.balances) { balance in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(balance.shortTokenAddress)
                        .font(.body.monospaced())
                    Text(balance.tokenAddress)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(balance.formattedAmount)
                    .font(.body.monospaced().bold())
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Actions

    private func loadBalances() async {
        guard let walletID = KeychainHelper.load(.walletID) else { return }
        isLoading = true
        isScanning = true
        errorMessage = nil
        scanStep = "Scanning merkletree..."
        scanProgress = 0
        scanPassCount = 0

        do {
            scanStep = "Loading balances..."
            balanceState.balances = try await balanceService?.getPrivateBalances(
                chainName: network.selectedChain.rawValue,
                walletID: walletID
            ) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
        scanStep = nil
        isLoading = false
    }

    // Each scan pass (utxo pass 1, utxo pass 2, txid) maps to a segment of the overall bar.
    private static let estimatedPasses = 3.0

    private func listenForScanEvents() {
        bridge.onEvent("scanProgress") { data in
            guard let dict = data as? [String: Any] else { return }
            let status = dict["scanStatus"] as? String
            let type = dict["type"] as? String
            let progress = dict["progress"] as? Double
            Task { @MainActor in
                guard isScanning else { return }

                if status == "Complete" {
                    scanPassCount += 1
                }

                if let status, let type {
                    scanStep = switch status {
                    case "Started": "Scanning \(type) merkletree..."
                    case "Updated": "Syncing \(type) merkletree..."
                    case "Complete": "Syncing \(type) merkletree..."
                    default: "Scanning..."
                    }
                }

                // Map each pass's 0→1 into an overall 0→1
                if let progress, status == "Updated" {
                    let passBase = Double(scanPassCount) / Self.estimatedPasses
                    let passProgress = min(progress, 1.0) / Self.estimatedPasses
                    let overall = min(passBase + passProgress, 1.0)
                    // Only move forward
                    if overall > scanProgress {
                        scanProgress = overall
                    }
                }
            }
        }
    }
}

// Response types are in WalletService.swift

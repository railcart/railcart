//
//  PrivateBalanceSection.swift
//  railcart
//
//  Private (ZK) address balance card showing RAILGUN shielded token balances.
//

import SwiftUI

struct PrivateBalanceSection: View {
    let railgunAddress: String
    let tokenBalances: [TokenBalance]
    let chain: Chain
    let isScanning: Bool
    let scanStep: String?
    let scanProgress: Double
    let errorMessage: String?
    let onRefresh: () -> Void

    var body: some View {
        BalanceCard {
            HStack {
                Label("Private (ZK) Address", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isScanning)
            }

            AddressPill(address: railgunAddress)

            if isScanning {
                VStack(spacing: 8) {
                    ProgressView(value: scanProgress) {
                        Text(scanStep ?? "Scanning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } currentValueLabel: {
                        Text("\(Int(scanProgress * 100))%")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            // Token balance grid
            LazyVGrid(columns: tokenGridColumns, spacing: 10) {
                let hasSynced = !tokenBalances.isEmpty || !isScanning
                ForEach(Token.supported) { token in
                    let address = token.address(on: chain)
                    let balance = address.flatMap { addr in
                        tokenBalances.first { $0.tokenAddress.lowercased() == addr.lowercased() }?.amount
                    }
                    // Show "0" after sync completes, "--" only while waiting for first sync
                    TokenRow(token: token, balance: balance ?? (hasSynced ? "0" : nil))
                }

                // Unknown tokens from scan
                let knownAddresses = Set(Token.supported.compactMap {
                    $0.address(on: chain)?.lowercased()
                })
                let unknownBalances = tokenBalances.filter {
                    !knownAddresses.contains($0.tokenAddress.lowercased())
                }
                ForEach(unknownBalances) { balance in
                    UnknownTokenRow(balance: balance)
                }
            }
        }
    }
}

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
    var onUnshield: ((Token) -> Void)? = nil

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
                    let displayBalance = balance ?? (hasSynced ? "0" : nil)
                    // Only WETH supports unshield-to-ETH today (base token path).
                    let isWETH = token.symbol == "WETH"
                    let state: TokenActionState = if !isWETH {
                        .unsupported
                    } else if hasNonZero(displayBalance) {
                        .enabled
                    } else {
                        .zeroBalance
                    }
                    TokenRow(
                        token: token,
                        balance: displayBalance,
                        action: .unshield,
                        actionState: state,
                        onAction: { onUnshield?(token) }
                    )
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

    private func hasNonZero(_ wei: String?) -> Bool {
        guard let wei, let value = Decimal(string: wei) else { return false }
        return value > 0
    }
}

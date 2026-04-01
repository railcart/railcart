//
//  PublicBalanceSection.swift
//  railcart
//
//  Public address balance card showing ETH and ERC-20 token balances.
//

import SwiftUI

struct PublicBalanceSection: View {
    let ethAddress: String
    let ethBalance: String?
    let tokenBalances: [String: String]  // lowercased tokenAddress -> amount
    let chain: Chain
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        BalanceCard {
            HStack {
                Label("Public Address", systemImage: "globe")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if isLoading {
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
                .disabled(isLoading)
            }

            AddressPill(address: ethAddress)

            // Token balance grid
            LazyVGrid(columns: tokenGridColumns, spacing: 10) {
                TokenRow(token: .eth, balance: ethBalance)

                ForEach(Token.supported) { token in
                    let address = token.address(on: chain)
                    let balance = address.flatMap { tokenBalances[$0.lowercased()] }
                    TokenRow(token: token, balance: balance)
                }
            }
        }
    }
}

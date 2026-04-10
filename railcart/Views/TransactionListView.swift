//
//  TransactionListView.swift
//  railcart
//
//  Local transaction history — shield, unshield, and private send records.
//

import SwiftUI

struct TransactionListView: View {
    @Environment(TransactionStore.self) private var store
    @Environment(NetworkState.self) private var network
    @Environment(WalletState.self) private var walletState

    var body: some View {
        let filtered = store.transactions(for: network.selectedChain.rawValue)

        VStack(spacing: 0) {
            HStack {
                Text("Transactions")
                    .font(.title2.bold())
                Spacer()
                Text(network.selectedChain.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(network.selectedChain.isTestnet ? .orange.opacity(0.15) : .blue.opacity(0.15),
                                in: Capsule())
                    .foregroundStyle(network.selectedChain.isTestnet ? .orange : .blue)
            }
            .padding()

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "clock",
                    description: Text("Shield or unshield tokens to see your transaction history here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(filtered) { tx in
                    TransactionRow(
                        transaction: tx,
                        accountName: walletState.account(byID: tx.fromAccountID)?.name
                    )
                }
            }
        }
        .frame(minWidth: 450, minHeight: 300)
    }
}

// MARK: - Transaction Row

struct TransactionRow: View {
    let transaction: Transaction
    let accountName: String?

    private var actionColor: Color {
        switch transaction.action {
        case .shield: .blue
        case .unshield: .orange
        case .privateSend: .purple
        }
    }

    private var actionLabel: String {
        switch transaction.action {
        case .shield: "Shield"
        case .unshield: "Unshield"
        case .privateSend: "Send"
        }
    }

    private var actionIcon: String {
        switch transaction.action {
        case .shield: "lock.shield.fill"
        case .unshield: "lock.open.fill"
        case .privateSend: "arrow.right"
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: transaction.timestamp)
    }

    private var shortHash: String {
        let h = transaction.txHash
        if h.count > 14 {
            return String(h.prefix(8)) + "..." + String(h.suffix(4))
        }
        return h
    }

    private var shortToAddress: String {
        let a = transaction.toAddress
        if a.count > 14 {
            return String(a.prefix(8)) + "..." + String(a.suffix(4))
        }
        return a
    }

    var body: some View {
        HStack(spacing: 12) {
            // Action icon
            Image(systemName: actionIcon)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(actionColor.gradient, in: Circle())

            // Details
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(actionLabel)
                        .font(.body.bold())
                        .foregroundStyle(actionColor)
                    if let accountName {
                        Text("from \(accountName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text("to")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(shortToAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Amount + metadata
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(transaction.amount) \(transaction.tokenSymbol)")
                    .font(.body.monospaced().bold())
                Text(formattedDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy TX Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transaction.txHash, forType: .string)
            }
            Button("Copy Destination") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transaction.toAddress, forType: .string)
            }
        }
    }
}

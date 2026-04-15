//
//  ProofsDebugView.swift
//  railcart
//
//  Debug-only view (sidebar entry gated by #if DEBUG) showing every
//  transaction the native scanner knows about for the selected chain,
//  along with POI bucket state per UTXO and parent-tx dependencies.
//
//  Useful for understanding why a UTXO is stuck in a non-spendable bucket
//  and what other txs its POI chain depends on.
//

#if DEBUG

import SwiftUI
import RailcartCrypto

struct ProofsDebugView: View {
    @Environment(\.balanceService) private var balanceService
    @Environment(WalletState.self) private var walletState
    @Environment(NetworkState.self) private var network

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if balanceService == nil {
                    Text("Balance service unavailable.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(walletState.wallets) { wallet in
                        walletSection(wallet: wallet)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Proofs")
                .font(.title2.bold())
            Text("\(network.selectedChain.displayName) · native scanner view")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Parent tx list is derived from our own spent UTXOs: if tx A consumed a UTXO that tx B created, A depends on B's POI being Valid.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func walletSection(wallet: Wallet) -> some View {
        let txs = balanceService?.nativeScanner.debugTransactions(
            chainName: network.selectedChain.rawValue,
            walletID: wallet.id
        ) ?? []

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(wallet.name)
                    .font(.headline)
                Text(wallet.id.prefix(8) + "...")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(txs.count) tx\(txs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if txs.isEmpty {
                Text("No transactions indexed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(txs) { tx in
                    TransactionCard(tx: tx)
                }
            }
        }
    }
}

private struct TransactionCard: View {
    let tx: NativeScannerService.DebugTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("tx")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(tx.txid)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                CopyButton(value: "0x" + tx.txid)
                Spacer()
                Text("block \(tx.blockNumber)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            if !tx.parentTxids.isEmpty {
                parentsRow
            }

            if !tx.createdUTXOs.isEmpty {
                utxoBlock(title: "Created", utxos: tx.createdUTXOs)
            }
            if !tx.spentUTXOs.isEmpty {
                utxoBlock(title: "Spent by this tx", utxos: tx.spentUTXOs)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var parentsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Depends on")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(tx.parentTxids, id: \.self) { parent in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(parent)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(value: "0x" + parent)
                }
            }
        }
    }

    private func utxoBlock(title: String, utxos: [NativeScannerService.DebugUTXO]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(utxos) { u in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(u.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 60, alignment: .leading)
                    Text(u.tokenDisplay)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(u.amountRaw)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if u.isSentNote {
                        Tag(label: "sent", color: .purple)
                    }
                    if u.isSpent {
                        Tag(label: "spent", color: .gray)
                    }
                    Tag(label: u.commitmentType, color: .blue)
                    BucketTag(bucket: u.bucket)
                    if let bc = u.blindedCommitment {
                        CopyButton(value: bc, help: "Copy blinded commitment")
                    }
                }
            }
        }
    }
}

private struct Tag: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct BucketTag: View {
    let bucket: WalletBalanceBucket

    var body: some View {
        Tag(label: bucket.rawValue, color: color)
    }

    private var color: Color {
        switch bucket {
        case .spendable: .green
        case .shieldPending, .proofSubmitted: .orange
        case .shieldBlocked, .missingInternalPOI, .missingExternalPOI: .red
        case .spent: .gray
        }
    }
}

private struct CopyButton: View {
    let value: String
    var help: String = "Copy"

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

#endif

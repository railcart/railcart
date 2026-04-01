//
//  PendingShieldView.swift
//  railcart
//
//  Shows tokens that have been shielded but are waiting for PPOI verification
//  before appearing in private balances. Displayed between public and private sections.
//

import SwiftUI

struct PendingShieldView: View {
    let transactions: [Transaction]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .symbolEffect(.pulse)
                    Text("Waiting for PPOI verification")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                ForEach(transactions) { tx in
                    pendingRow(tx, now: context.date)
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.yellow.opacity(0.06))
                    .strokeBorder(.yellow.opacity(0.2), lineWidth: 1)
            }
        }
    }

    private func pendingRow(_ tx: Transaction, now: Date) -> some View {
        HStack(spacing: 12) {
            let token = Token.supported.first { $0.symbol == tx.tokenSymbol } ?? .eth
            TokenIconView(assetName: token.iconAsset)
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Shield")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                    Text("\(tx.amount) \(tx.tokenSymbol)")
                        .font(.caption.monospaced().bold())
                }
                Text(shortHash(tx.txHash))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(elapsed(since: tx.timestamp, now: now))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let m = seconds / 60
        let s = seconds % 60
        if m >= 60 {
            let h = m / 60
            return String(format: "%d:%02d:%02d", h, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func shortHash(_ hash: String) -> String {
        if hash.count > 14 {
            return String(hash.prefix(8)) + "..." + String(hash.suffix(4))
        }
        return hash
    }
}

//
//  TokenComponents.swift
//  railcart
//
//  Reusable UI components for token display and address formatting.
//

import SwiftUI

struct AddressPill: View {
    let address: String

    var body: some View {
        HStack(spacing: 6) {
            Text(address)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TokenIconView: View {
    let assetName: String

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 32, height: 32)
            .clipShape(Circle())
    }
}

struct TokenRow: View {
    let token: Token
    let balance: String?

    var body: some View {
        HStack(spacing: 10) {
            TokenIconView(assetName: token.iconAsset)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.symbol)
                    .font(.body.bold())
                Text(token.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(balance.map { token.formatBalance($0) } ?? "--")
                .font(.body.monospaced().bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UnknownTokenRow: View {
    let balance: TokenBalance

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unknown")
                    .font(.body.bold())
                HStack(spacing: 4) {
                    Text(balance.tokenAddress)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(balance.tokenAddress, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy contract address")
                }
            }
            Spacer(minLength: 4)
            Text(balance.formattedAmount)
                .font(.body.monospaced().bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Adaptive grid columns for token cells.
let tokenGridColumns = [GridItem(.adaptive(minimum: 200, maximum: 350), spacing: 10)]

/// Card background used by both public and private balance sections.
struct BalanceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
                .shadow(color: .primary.opacity(0.08), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}

func formatWei(_ wei: String) -> String {
    guard let value = Decimal(string: wei), value != 0 else { return "0.00" }
    let eth = value / 1_000_000_000_000_000_000
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 6
    formatter.numberStyle = .decimal
    return formatter.string(from: eth as NSDecimalNumber) ?? "0.00"
}

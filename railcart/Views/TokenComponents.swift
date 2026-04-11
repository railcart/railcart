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

enum TokenCellAction {
    case shield      // public → private
    case unshield    // private → public/elsewhere

    var systemImage: String {
        switch self {
        case .shield: "arrow.down"
        case .unshield: "arrow.up.right"
        }
    }

    var label: String {
        switch self {
        case .shield: "Shield"
        case .unshield: "Unshield"
        }
    }
}

enum TokenActionState {
    case enabled
    case zeroBalance
    case unsupported    // backend doesn't implement this token's shield/unshield yet
    case hidden
}

struct TokenRow: View {
    let token: Token
    let balance: String?
    var action: TokenCellAction? = nil
    var actionState: TokenActionState = .hidden
    var onAction: (() -> Void)? = nil

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
            VStack(alignment: .trailing, spacing: 6) {
                Text(balance.map { token.formatBalance($0) } ?? "--")
                    .font(.body.monospaced().bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let action, actionState != .hidden {
                    actionPill(action, state: actionState, action: onAction)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func actionPill(_ cellAction: TokenCellAction, state: TokenActionState, action: (() -> Void)?) -> some View {
        let enabled = state == .enabled
        Button {
            action?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: cellAction.systemImage)
                Text(cellAction.label)
            }
            .fixedSize()
            .font(.caption.bold())
            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(enabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .overlay(
                Capsule().strokeBorder(
                    enabled ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(tooltip(for: cellAction, state: state))
    }

    private func tooltip(for action: TokenCellAction, state: TokenActionState) -> String {
        switch state {
        case .enabled: action.label
        case .zeroBalance: "No \(token.symbol) to \(action.label.lowercased())"
        case .unsupported: "\(action.label) for \(token.symbol) coming soon"
        case .hidden: ""
        }
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

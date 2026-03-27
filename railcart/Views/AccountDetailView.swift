//
//  AccountDetailView.swift
//  railcart
//
//  Detail view for a single wallet account.
//

import SwiftUI

struct AccountDetailView: View {
    @Environment(\.balanceService) private var balanceService
    @Environment(WalletState.self) private var walletState
    @Environment(NetworkState.self) private var network

    let accountID: String

    @State private var ethBalance: String?
    @State private var isEditingName = false
    @FocusState private var nameFieldFocused: Bool

    private var account: Account? {
        walletState.account(byID: accountID)
    }

    private var unlocked: Account.Unlocked? {
        walletState.unlockedKeys[accountID]
    }

    var body: some View {
        if let account, let unlocked {
            accountView(account: account, unlocked: unlocked)
        } else {
            ContentUnavailableView(
                "Account Not Found",
                systemImage: "exclamationmark.triangle",
                description: Text("This account could not be loaded.")
            )
        }
    }

    private func accountView(account: Account, unlocked: Account.Unlocked) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            walletNameView(account: account)

            addressRow(label: "RAILGUN Address", address: account.railgunAddress)
            addressRow(label: "ETH Address (\(network.selectedChain.displayName))", address: unlocked.ethAddress)

            if let ethBalance {
                Text("\(ethBalance) ETH")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 300)
        .task { await fetchEthBalance(address: unlocked.ethAddress) }
        .onChange(of: network.selectedChain) {
            ethBalance = nil
            Task { await fetchEthBalance(address: unlocked.ethAddress) }
        }
    }

    @ViewBuilder
    private func walletNameView(account: Account) -> some View {
        HStack(spacing: 6) {
            if isEditingName {
                let binding = Binding<String>(
                    get: { account.name },
                    set: { newName in
                        if let idx = walletState.accounts.firstIndex(where: { $0.id == accountID }) {
                            walletState.accounts[idx].name = newName
                        }
                    }
                )
                TextField("Wallet Name", text: binding)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .onSubmit { isEditingName = false }
                    .onChange(of: nameFieldFocused) {
                        if !nameFieldFocused { isEditingName = false }
                    }
            } else {
                Text(account.name)
                    .font(.title2.bold())
                Button {
                    isEditingName = true
                    nameFieldFocused = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func addressRow(label: String, address: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(address)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
            }
            .padding(8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: 500)
    }

    private func fetchEthBalance(address: String) async {
        guard let balanceService else { return }
        do {
            let balance = try await balanceService.getEthBalance(
                chainName: network.selectedChain.rawValue,
                address: address
            )
            ethBalance = formatWei(balance)
        } catch {}
    }

    private func formatWei(_ wei: String) -> String {
        guard let value = Decimal(string: wei) else { return "0" }
        let eth = value / 1_000_000_000_000_000_000
        return (eth as NSDecimalNumber).stringValue
    }
}

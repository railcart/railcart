//
//  ContentView.swift
//  railcart
//
//

import SwiftUI

struct ContentView: View {
    @Environment(NodeBridge.self) private var bridge
    @Environment(\.walletService) private var service
    @Environment(\.balanceService) private var balanceService
    @Environment(NetworkState.self) private var network
    @Environment(BalanceState.self) private var balanceState
    @Environment(WalletState.self) private var walletState

    @State private var isAddingWallet = false

    var body: some View {
        @Bindable var network = network
        NavigationSplitView {
            List {
                Section("Wallets") {
                    ForEach(walletState.accounts) { account in
                        NavigationLink {
                            AccountDetailView(accountID: account.id)
                        } label: {
                            Label(account.name, systemImage: "wallet.bifold")
                        }
                    }
                    Button {
                        Task { await addWallet() }
                    } label: {
                        Label(isAddingWallet ? "Creating..." : "Add Wallet", systemImage: "plus")
                    }
                    .foregroundStyle(.secondary)
                    .disabled(walletState.step != .ready || isAddingWallet)
                }
                Section("Actions") {
                    NavigationLink {
                        ShieldView()
                    } label: {
                        Label("Shield", systemImage: "shield.lefthalf.filled")
                    }
                    NavigationLink {
                        BalanceView()
                    } label: {
                        Label("Balances", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .navigationTitle("RAILGUN")
        } detail: {
            if bridge.isReady {
                if walletState.step == .ready, let first = walletState.accounts.first {
                    AccountDetailView(accountID: first.id)
                } else {
                    WalletSetupView()
                }
            } else if let error = bridge.errorMessage {
                ContentUnavailableView {
                    Label("Backend Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { try? await bridge.start() }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting backend...")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Network", selection: $network.selectedChain) {
                    ForEach(Chain.allCases) { chain in
                        Text(chain.displayName).tag(chain)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .onChange(of: network.selectedChain) {
            balanceState.balances = []
        }
    }

    private func addWallet() async {
        guard let encryptionKey = KeychainHelper.load(.encryptionKey),
              let firstAccount = walletState.accounts.first else { return }

        isAddingWallet = true
        defer { isAddingWallet = false }

        let index = walletState.nextDerivationIndex

        do {
            // Retrieve the mnemonic from the first wallet
            let mnemonic = try await service.getWalletMnemonic(
                encryptionKey: encryptionKey,
                walletID: firstAccount.id
            )

            // Create a new RAILGUN wallet at the next derivation index
            let walletInfo = try await service.createWallet(
                encryptionKey: encryptionKey,
                mnemonic: mnemonic,
                derivationIndex: index
            )

            let account = Account(
                id: walletInfo.id,
                derivationIndex: walletInfo.derivationIndex,
                railgunAddress: walletInfo.railgunAddress,
                name: "Wallet \(index + 1)"
            )
            let unlocked = Account.Unlocked(
                ethAddress: walletInfo.ethAddress,
                ethPrivateKey: walletInfo.ethPrivateKey
            )
            walletState.addAccount(account, unlocked: unlocked)
        } catch {
            // TODO: surface error to user
        }
    }
}

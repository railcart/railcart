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
    @Environment(WalletState.self) private var walletState

    @State private var isAddingWallet = false
    @State private var selection: SidebarItem?

    enum SidebarItem: Hashable {
        case account(String)  // account ID
        case shield
        case transactions
    }

    var body: some View {
        @Bindable var network = network
        NavigationSplitView {
            List(selection: $selection) {
                Section("Wallets") {
                    ForEach(walletState.accounts) { account in
                        NavigationLink(value: SidebarItem.account(account.id)) {
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
                    NavigationLink(value: SidebarItem.shield) {
                        Label("Shield", systemImage: "shield.lefthalf.filled")
                    }
                    NavigationLink(value: SidebarItem.transactions) {
                        Label("Transactions", systemImage: "clock")
                    }
                }
            }
            .navigationTitle("RAILGUN")
            .accessibilityIdentifier("mainSidebar")
            .onChange(of: walletState.step) {
                if walletState.step == .ready, selection == nil,
                   let first = walletState.accounts.first {
                    selection = .account(first.id)
                }
            }
            .onAppear {
                if let first = walletState.accounts.first {
                    selection = .account(first.id)
                }
            }
        } detail: {
            switch selection {
            case .account(let id):
                AccountDetailView(accountID: id)
                    .id(id)
            case .shield:
                ShieldView()
            case .transactions:
                TransactionListView()
            case nil:
                if let error = bridge.errorMessage {
                    ContentUnavailableView {
                        Label("Backend Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { try? await bridge.start() }
                        }
                    }
                } else if !bridge.isReady {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting backend...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        "No Wallets",
                        systemImage: "wallet.bifold",
                        description: Text("Create a wallet to get started.")
                    )
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { bridge.isReady && walletState.step != .ready },
            set: { _ in }
        )) {
            WalletSetupView()
                .interactiveDismissDisabled()
        }
        .task { listenForScanEvents() }
        .onChange(of: walletState.step) {
            if walletState.step == .ready {
                Task { await syncPrivateBalances() }
            }
        }
        .onChange(of: network.selectedChain) {
            Task { await syncPrivateBalances() }
        }
        .toolbar(removing: .sidebarToggle)
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
    }

    private static let estimatedPasses = 3.0

    private func listenForScanEvents() {
        var passCount = 0
        var lastGeneration = -1
        bridge.onEvent("scanProgress") { data in
            guard let dict = data as? [String: Any],
                  let balanceService else { return }
            let status = dict["scanStatus"] as? String
            let type = dict["type"] as? String
            let progress = dict["progress"] as? Double
            Task { @MainActor in
                guard balanceService.isScanning else { return }
                // Reset pass count when a new scan starts
                if balanceService.scanGeneration != lastGeneration {
                    lastGeneration = balanceService.scanGeneration
                    passCount = 0
                }
                if status == "Complete" { passCount += 1 }
                var step: String?
                if let status, let type {
                    step = switch status {
                    case "Started": "Scanning \(type) merkletree..."
                    case "Updated": "Syncing \(type) merkletree..."
                    case "Complete": "Syncing \(type) merkletree..."
                    default: "Scanning..."
                    }
                }
                var overall = 0.0
                if let progress, status == "Updated" {
                    let passBase = Double(passCount) / Self.estimatedPasses
                    let passProgress = min(progress, 1.0) / Self.estimatedPasses
                    overall = min(passBase + passProgress, 1.0)
                }
                balanceService.updateScanProgress(step: step, progress: overall)
            }
        }
    }

    private func syncPrivateBalances() async {
        guard walletState.step == .ready, let balanceService else { return }
        let chain = network.selectedChain
        let walletIDs = walletState.accounts.map(\.id)
        guard !walletIDs.isEmpty else { return }
        guard !balanceService.hasAllPrivateBalances(chainName: chain.rawValue, walletIDs: walletIDs) else { return }
        try? await network.ensureProviderLoaded(for: chain, using: service)
        await balanceService.scanAllPrivateBalances(chainName: chain.rawValue, walletIDs: walletIDs)
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

            // Fetch current block numbers so the SDK skips scanning older blocks
            var creationBlocks: [String: Int] = [:]
            for chainName in Config.chainProviders.keys {
                if let block = try? await service.getBlockNumber(chainName: chainName) {
                    creationBlocks[chainName] = block
                }
            }

            // Create a new RAILGUN wallet at the next derivation index
            let walletInfo = try await service.createWallet(
                encryptionKey: encryptionKey,
                mnemonic: mnemonic,
                derivationIndex: index,
                creationBlockNumbers: creationBlocks
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

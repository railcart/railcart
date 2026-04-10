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
    @Environment(UpdateController.self) private var updateController

    @State private var selection: SidebarItem?
    @State private var visibleProviderError: ProviderError?

    enum SidebarItem: Hashable {
        case account(String)  // account ID
        case transactions
        case settings
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
                }
                Section("Actions") {
                    NavigationLink(value: SidebarItem.transactions) {
                        Label("Transactions", systemImage: "clock")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                List(selection: $selection) {
                    NavigationLink(value: SidebarItem.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .scrollDisabled(true)
                .frame(height: 40)
                .scrollContentBackground(.hidden)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            .toolbar(removing: .sidebarToggle)
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
            case .transactions:
                TransactionListView()
            case .settings:
                SettingsView()
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
        .overlay(alignment: .top) {
            if let error = visibleProviderError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                    Text("Failed to connect to \(error.chain.displayName). Configure a custom RPC provider in Settings.")
                        .foregroundStyle(.white)
                        .font(.callout)
                    Spacer()
                    Button("Settings") {
                        selection = .settings
                        visibleProviderError = nil
                        network.providerError = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.red)
                    .controlSize(.small)
                    Button {
                        visibleProviderError = nil
                        network.providerError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visibleProviderError)
        .onChange(of: network.providerError) {
            if network.providerError == nil {
                visibleProviderError = nil
            } else {
                let snapshot = network.providerError
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    // Only show if the error is still present and unchanged
                    if network.providerError == snapshot {
                        visibleProviderError = snapshot
                    }
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
            AppLogger.shared.log("sync", "Chain switched to \(network.selectedChain.rawValue)")
            balanceService?.resetScanState()
            Task { await syncPrivateBalances() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await walletState.addWallet(using: service) }
                } label: {
                    Label("Add Wallet", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(walletState.step != .ready || walletState.isAddingWallet)
            }
            ToolbarItem(placement: .automatic) {
                Picker("Network", selection: $network.selectedChain) {
                    ForEach(Chain.allCases) { chain in
                        Text(chain.displayName).tag(chain)
                    }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(updateController.updateAvailable ? Color.accentColor : Color.primary)
                }
                .help(updateController.updateAvailable ? "Update available" : "Check for updates")
            }
        }
    }

    private func listenForScanEvents() {
        bridge.onEvent("scanProgress") { data in
            guard let dict = data as? [String: Any],
                  let balanceService else { return }
            let status = dict["scanStatus"] as? String
            let type = dict["type"] as? String
            let progress = dict["progress"] as? Double
            let eventChainId = dict["chainId"] as? Int
            Task { @MainActor in
                guard balanceService.isScanning else { return }
                // Ignore events from a chain we're not currently displaying
                if let eventChainId, eventChainId != network.selectedChain.chainId { return }
                var step: String?
                if let status, let type {
                    step = switch status {
                    case "Started": "Scanning \(type) merkletree..."
                    case "Updated": "Syncing \(type) merkletree..."
                    case "Complete": "\(type) merkletree complete"
                    default: "Scanning..."
                    }
                }
                let overall = min(progress ?? 0, 1.0)
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

}

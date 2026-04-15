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
        case wallet(String)  // wallet ID
        case transactions
        case settings
        #if DEBUG
        case proofs
        #endif
    }

    var body: some View {
        @Bindable var network = network
        NavigationSplitView {
            List(selection: $selection) {
                Section("Wallets") {
                    ForEach(walletState.wallets) { wallet in
                        NavigationLink(value: SidebarItem.wallet(wallet.id)) {
                            Label(wallet.name, systemImage: "wallet.bifold")
                        }
                    }
                }
                Section("Info") {
                    NavigationLink(value: SidebarItem.transactions) {
                        Label("Transactions", systemImage: "clock")
                    }
                    #if DEBUG
                    NavigationLink(value: SidebarItem.proofs) {
                        Label("Proofs", systemImage: "ladybug")
                    }
                    #endif
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
                   let first = walletState.wallets.first {
                    selection = .wallet(first.id)
                }
            }
            .onAppear {
                if let first = walletState.wallets.first {
                    selection = .wallet(first.id)
                }
            }
        } detail: {
            switch selection {
            case .wallet(let id):
                WalletDetailView(walletID: id)
                    .id(id)
            case .transactions:
                TransactionListView()
            case .settings:
                SettingsView()
            #if DEBUG
            case .proofs:
                ProofsDebugView()
            #endif
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
            get: { bridge.isEngineReady && walletState.step != .ready },
            set: { _ in }
        )) {
            WalletSetupView()
                .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            walletState.handleAppActivation()
        }
        .onChange(of: walletState.step) {
            if walletState.step == .ready {
                Task { await syncPrivateBalances() }
            }
        }
        .onChange(of: network.selectedChain) {
            AppLogger.shared.log("sync", "Chain switched to \(network.selectedChain.rawValue)")
            network.providerError = nil
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
                    Image(systemName: updateController.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle")
                        .foregroundStyle(updateController.updateAvailable ? Color.accentColor : Color.secondary)
                }
                .help(updateController.updateAvailable ? "Update available" : "Up to date")
            }
        }
    }

    private func syncPrivateBalances() async {
        guard walletState.step == .ready, let balanceService else { return }
        let chain = network.selectedChain
        let walletIDs = walletState.wallets.map(\.id)
        guard !walletIDs.isEmpty else { return }
        guard !balanceService.hasAllPrivateBalances(chainName: chain.rawValue, walletIDs: walletIDs) else { return }
        do {
            try await network.ensureProviderLoaded(for: chain, using: service)
        } catch {
            AppLogger.shared.log("sync", "Skipping private balance sync — no provider for \(chain.rawValue)")
            return
        }
        await balanceService.scanAllPrivateBalances(chainName: chain.rawValue, wallets: walletState.wallets)
    }

}

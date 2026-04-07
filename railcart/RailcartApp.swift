//
//  RailcartApp.swift
//  railcart
//
//

import SwiftUI

@main
struct RailcartApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var bridge: NodeBridge
    @State private var walletService: LiveWalletService
    @State private var balanceService: BalanceService
    @State private var walletState: WalletState
    @State private var broadcasterState = BroadcasterState()
    @State private var networkState = NetworkState()
    @State private var transactionStore: TransactionStore

    static let isUITesting = CommandLine.arguments.contains("--ui-testing")

    init() {
        if Self.isUITesting {
            KeychainHelper.service = "app.railcart.macos.uitesting"
            KeychainHelper.biometryDisabled = true
            let testDefaults = UserDefaults(suiteName: "app.railcart.macos.uitesting")!
            testDefaults.removePersistentDomain(forName: "app.railcart.macos.uitesting")
            Account.defaults = testDefaults
            KeychainHelper.delete(.walletID)
            KeychainHelper.delete(.walletSalt)
            KeychainHelper.delete(.encryptionKey)
        }

        // Create state objects after test isolation is configured
        _walletState = State(initialValue: WalletState())
        _transactionStore = State(initialValue: TransactionStore())

        let bridge = NodeBridge()
        let service = LiveWalletService(bridge: bridge)
        _bridge = State(initialValue: bridge)
        _walletService = State(initialValue: service)
        _balanceService = State(initialValue: BalanceService(walletService: service))
    }

    var body: some Scene {
        Window("railcart", id: "main") {
            ContentView()
                .sheet(isPresented: Binding(
                    get: { walletState.showImportSheet },
                    set: { walletState.showImportSheet = $0 }
                )) {
                    ImportWalletView()
                }
                .environment(\.walletService, walletService)
                .environment(\.balanceService, balanceService)
                .environment(bridge)
                .environment(walletState)
                .environment(broadcasterState)
                .environment(networkState)
                .environment(transactionStore)
                .task {
                    try? await bridge.start()
                    if Self.isUITesting {
                        let testDir = NSTemporaryDirectory() + "railcart-uitest"
                        try? await bridge.callRaw("initEngine", params: ["dataDir": testDir])
                    } else {
                        try? await bridge.callRaw("initEngine")
                    }
                    // Load provider for the initial chain only; others load on demand
                    try? await networkState.ensureProviderLoaded(
                        for: networkState.selectedChain, using: walletService
                    )
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Wallet") {
                    Task { await walletState.addWallet(using: walletService) }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(walletState.step != .ready || walletState.isAddingWallet)
                Button("Import Wallet...") {
                    walletState.showImportSheet = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(walletState.step != .ready)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Debug Log") {
                    openWindow(id: "debug-log")
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }

        Window("Debug Log", id: "debug-log") {
            LogWindowView()
        }
    }
}

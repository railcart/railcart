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
    @State private var walletService: any WalletServiceProtocol
    @State private var balanceService: BalanceService
    @State private var walletState: WalletState
    @State private var broadcasterState: BroadcasterState
    @State private var networkState: NetworkState
    @State private var transactionStore: TransactionStore
    @State private var updateController = UpdateController()
    private let keychain: any KeychainProviding

    static let isUITesting = CommandLine.arguments.contains("--ui-testing")
    static let demoScenario = DemoScenario.parse(arguments: CommandLine.arguments)

    init() {
        if let scenario = Self.demoScenario {
            // Demo/screenshot mode: every dependency is in-memory and pre-seeded.
            // No Node.js process, no Keychain reads, no network.
            let seed = DemoSeeder.build(scenario)
            _bridge = State(initialValue: seed.bridge)
            _walletService = State(initialValue: seed.walletService)
            _balanceService = State(initialValue: seed.balanceService)
            _walletState = State(initialValue: seed.walletState)
            _broadcasterState = State(initialValue: seed.broadcasterState)
            _networkState = State(initialValue: seed.networkState)
            _transactionStore = State(initialValue: seed.transactionStore)
            keychain = seed.keychain
            return
        }

        if Self.isUITesting {
            KeychainHelper.service = "app.railcart.macos.uitesting"
            KeychainHelper.biometryDisabled = true
            let testDefaults = UserDefaults(suiteName: "app.railcart.macos.uitesting")!
            testDefaults.removePersistentDomain(forName: "app.railcart.macos.uitesting")
            RailcartDefaults.store = testDefaults
            KeychainHelper.delete(.walletID)
            KeychainHelper.delete(.walletSalt)
            KeychainHelper.delete(.encryptionKey)
        }

        // Create state objects after test isolation is configured
        let liveKeychain = LiveKeychainProvider()
        keychain = liveKeychain
        _walletState = State(initialValue: WalletState())
        _transactionStore = State(initialValue: TransactionStore())
        _broadcasterState = State(initialValue: BroadcasterState())
        _networkState = State(initialValue: NetworkState())

        let bridge = NodeBridge()
        let service = LiveWalletService(bridge: bridge)
        _bridge = State(initialValue: bridge)
        _walletService = State(initialValue: service)
        _balanceService = State(initialValue: BalanceService(walletService: service, keychain: liveKeychain))
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
                #if DEBUG
                .sheet(isPresented: Binding(
                    get: { walletState.showReplaceMnemonicSheet },
                    set: { walletState.showReplaceMnemonicSheet = $0 }
                )) {
                    ReplaceCoreMnemonicView()
                }
                #endif
                .environment(\.walletService, walletService)
                .environment(\.balanceService, balanceService)
                .environment(\.keychain, keychain)
                .environment(bridge)
                .environment(walletState)
                .environment(broadcasterState)
                .environment(networkState)
                .environment(transactionStore)
                .environment(updateController)
                .task {
                    guard Self.demoScenario == nil else { return }
                    try? await bridge.start()
                    var initParams: [String: String] = [:]
                    if Self.isUITesting {
                        initParams["dataDir"] = NSTemporaryDirectory() + "railcart-uitest"
                    }
                    if let customEthRPC = networkState.customRPCURLs[.ethereum] {
                        initParams["ethereumRpcUrl"] = customEthRPC
                    }
                    _ = try? await bridge.callRaw("initEngine", params: initParams)
                    bridge.isEngineReady = true
                    // Load provider for the initial chain only; others load on demand
                    try? await networkState.ensureProviderLoaded(
                        for: networkState.selectedChain, using: walletService
                    )
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Wallet") {
                    Task { await walletState.addWallet(using: walletService, keychain: keychain) }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(walletState.step != .ready || walletState.isAddingWallet)
                Button("Import Wallet...") {
                    walletState.showImportSheet = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(walletState.step != .ready)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Full Balance Rescan") {
                    Task {
                        guard let bs = balanceService as BalanceService? else { return }
                        bs.nativeScanner.clearSavedState(walletIDs: walletState.wallets.map(\.id), chainName: networkState.selectedChain.rawValue)
                        bs.invalidateAllPrivateBalances(chainName: networkState.selectedChain.rawValue)
                        await bs.scanAllPrivateBalances(chainName: networkState.selectedChain.rawValue, wallets: walletState.wallets)
                    }
                }
                .disabled(walletState.step != .ready || (balanceService.isScanning))
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Debug Log") {
                    openWindow(id: "debug-log")
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                #if DEBUG
                Divider()
                Button("Replace Core Mnemonic…") {
                    walletState.showReplaceMnemonicSheet = true
                }
                .disabled(walletState.step != .ready)
                #endif
            }
        }

        Window("Debug Log", id: "debug-log") {
            LogWindowView()
        }
        .commandsRemoved()
    }
}

//
//  RailcartApp.swift
//  railcart
//
//

import SwiftUI
@main
struct RailcartApp: App {
    @State private var bridge: NodeBridge
    @State private var walletService: LiveWalletService
    @State private var balanceService: BalanceService
    @State private var walletState = WalletState()
    @State private var balanceState = BalanceState()
    @State private var shieldState = ShieldState()
    @State private var broadcasterState = BroadcasterState()
    @State private var networkState = NetworkState()

    init() {
        let bridge = NodeBridge()
        let service = LiveWalletService(bridge: bridge)
        _bridge = State(initialValue: bridge)
        _walletService = State(initialValue: service)
        _balanceService = State(initialValue: BalanceService(walletService: service))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.walletService, walletService)
                .environment(\.balanceService, balanceService)
                .environment(bridge)
                .environment(walletState)
                .environment(balanceState)
                .environment(shieldState)
                .environment(broadcasterState)
                .environment(networkState)
                .task {
                    try? await bridge.start()
                    try? await bridge.callRaw("initEngine")
                    // Load chain providers from build config
                    for (chain, url) in Config.chainProviders where !url.isEmpty {
                        try? await walletService.loadChainProvider(chainName: chain, providerUrl: url)
                    }
                }
        }
    }
}

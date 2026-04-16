//
//  DemoScenario.swift
//  railcart
//
//  Read-only demo modes for screenshot generation.
//  Activated via `--demo=<scenario>` launch arg in RailcartApp.
//
//  Scenarios pre-seed every observable state object so views render
//  deterministic content without hitting Keychain, Node.js, or the network.
//

import Foundation
import RailcartCrypto

enum DemoScenario: String, CaseIterable {
    case emptyWallet = "empty-wallet"
    case walletWithBalance = "wallet-with-balance"
    case midScan = "mid-scan"
    case broadcastersFound = "broadcasters-found"
    case unshieldPending = "unshield-pending"
    case settings = "settings"

    static func parse(arguments: [String]) -> DemoScenario? {
        for arg in arguments {
            guard arg.hasPrefix("--demo=") else { continue }
            let name = String(arg.dropFirst("--demo=".count))
            return DemoScenario(rawValue: name)
        }
        return nil
    }
}

@MainActor
struct DemoSeed {
    let bridge: NodeBridge
    let walletService: any WalletServiceProtocol
    let keychain: any KeychainProviding
    let walletState: WalletState
    let balanceService: BalanceService
    let broadcasterState: BroadcasterState
    let networkState: NetworkState
    let transactionStore: TransactionStore
}

@MainActor
enum DemoSeeder {
    /// Stable wallet IDs used across scenarios so screenshots are reproducible.
    ///
    /// Public addresses use obvious "magic hex" demo patterns (DEAD/CAFE/BABE/F00D)
    /// so anyone inspecting a screenshot on a block explorer can immediately
    /// tell these aren't real user addresses, and so we don't accidentally
    /// publish activity for any actual on-chain identity.
    private enum IDs {
        static let primaryWallet = "demo-wallet-primary"
        static let secondaryWallet = "demo-wallet-secondary"
        static let primaryEth = "0xDEADBEEFCAFEBABEDEADBEEFCAFEBABEDEADBEEF"
        static let secondaryEth = "0xF00DBABEF00DBABEF00DBABEF00DBABEF00DBABE"
        static let primaryRailgun = "0zk1qyvc73e0kkzcpvccrcvznndp52gqvun7c4yzks7m4l5xpyh4yqwhvrv7j6fe3z53lugc08rj0cy0sa3v59ekju5tn5jx5avcdr8je7wxq8fda6jdf3qfg4wnrfnwggas4u"
        static let secondaryRailgun = "0zk1q8hdv5yvz0v6w0fwqwq2j8e8x4qy0c2vw6z7e2y0hkj9hpa4wvchqp0g6lf04jdq6acxgs8j7y0w0xafs6lfx5lhd0wch08mu4tj98rl6c0t8vyv8pxw8nldrkmhz04"
    }

    /// Decode the launch arg and assemble every observable bound into the
    /// SwiftUI environment. Returns nil when no scenario is selected.
    static func build(_ scenario: DemoScenario) -> DemoSeed {
        // Isolate UserDefaults so demo settings (custom RPCs, lock timeout)
        // never leak into the user's real preferences. The suite is wiped
        // at the start of every demo launch.
        let suite = "app.railcart.macos.demo"
        let demoDefaults = UserDefaults(suiteName: suite)!
        demoDefaults.removePersistentDomain(forName: suite)
        RailcartDefaults.store = demoDefaults

        let walletService = MockWalletService()
        let keychain = DemoKeychainProvider(values: [
            .walletID: IDs.primaryWallet,
            .walletSalt: "demo-salt",
            .encryptionKey: "demo-encryption-key",
        ])
        let bridge = NodeBridge()
        bridge.enterDemoMode()

        let balanceService = BalanceService(walletService: walletService, keychain: keychain)
        let walletState = WalletState()
        let broadcasterState = BroadcasterState()
        let networkState = NetworkState()
        let transactionStore = TransactionStore()
        // Prevent the auto-lock timer from firing during a long screenshot session.
        walletState.lockTimeout = .never

        // Most scenarios show the Ethereum mainnet view rather than Sepolia
        // so screenshots match the production-default chain.
        networkState.selectedChain = scenario == .settings ? .ethereum : .ethereum

        switch scenario {
        case .emptyWallet:
            seedEmptyWallet(walletState: walletState, balanceService: balanceService)
        case .walletWithBalance:
            seedTwoWallets(walletState: walletState, balanceService: balanceService)
            seedTransactions(transactionStore)
        case .midScan:
            seedTwoWallets(walletState: walletState, balanceService: balanceService)
            balanceService.seedScanProgress(
                chainName: Chain.ethereum.rawValue,
                step: "Scanning merkletree (block 19,420,000 / 19,500,000)",
                progress: 0.42
            )
        case .broadcastersFound:
            seedTwoWallets(walletState: walletState, balanceService: balanceService)
            seedBroadcasters(broadcasterState)
        case .unshieldPending:
            seedTwoWallets(walletState: walletState, balanceService: balanceService)
            seedTransactions(transactionStore, includeRecentUnshield: true)
            seedPendingPOI(balanceService: balanceService, walletID: IDs.primaryWallet)
        case .settings:
            seedTwoWallets(walletState: walletState, balanceService: balanceService)
            networkState.setCustomRPCURL("https://demo.eth.example/v1/abc123", for: .ethereum)
        }

        walletState.setStep(.ready)

        return DemoSeed(
            bridge: bridge,
            walletService: walletService,
            keychain: keychain,
            walletState: walletState,
            balanceService: balanceService,
            broadcasterState: broadcasterState,
            networkState: networkState,
            transactionStore: transactionStore
        )
    }

    // MARK: - Builders

    private static func seedEmptyWallet(walletState: WalletState, balanceService: BalanceService) {
        let primary = Wallet(
            id: IDs.primaryWallet,
            derivationIndex: 0,
            railgunAddress: IDs.primaryRailgun,
            name: "Wallet 1",
            creationBlockNumbers: [Chain.ethereum.rawValue: 19_500_000]
        )
        walletState.setWalletsForPreview([primary])
        walletState.unlockedKeys[primary.id] = Wallet.Unlocked(
            ethAddress: IDs.primaryEth,
            ethPrivateKey: ""
        )
        let chain = Chain.ethereum.rawValue
        balanceService.seedPrivateBalances(chainName: chain, walletID: primary.id, balances: [])
        balanceService.seedEthBalance(chainName: chain, address: IDs.primaryEth, balance: "0")
        balanceService.seedERC20Balances(chainName: chain, address: IDs.primaryEth, balances: [])
    }

    private static func seedTwoWallets(walletState: WalletState, balanceService: BalanceService) {
        let primary = Wallet(
            id: IDs.primaryWallet,
            derivationIndex: 0,
            railgunAddress: IDs.primaryRailgun,
            name: "Main",
            creationBlockNumbers: [Chain.ethereum.rawValue: 19_500_000]
        )
        let secondary = Wallet(
            id: IDs.secondaryWallet,
            derivationIndex: 1,
            railgunAddress: IDs.secondaryRailgun,
            name: "Savings",
            creationBlockNumbers: [Chain.ethereum.rawValue: 19_500_000]
        )
        walletState.setWalletsForPreview([primary, secondary])
        walletState.unlockedKeys[primary.id] = Wallet.Unlocked(
            ethAddress: IDs.primaryEth,
            ethPrivateKey: ""
        )
        walletState.unlockedKeys[secondary.id] = Wallet.Unlocked(
            ethAddress: IDs.secondaryEth,
            ethPrivateKey: ""
        )

        let chain = Chain.ethereum.rawValue
        let weth = Token.weth.address(on: .ethereum)!
        let usdc = Token.usdc.address(on: .ethereum)!
        let usdt = Token.usdt.address(on: .ethereum)!

        balanceService.seedPrivateBalances(chainName: chain, walletID: primary.id, balances: [
            TokenBalance(tokenAddress: weth, amount: "1820000000000000000"),  // 1.82 WETH
            TokenBalance(tokenAddress: usdc, amount: "4250000000"),           // 4,250 USDC
        ])
        balanceService.seedPrivateBalances(chainName: chain, walletID: secondary.id, balances: [
            TokenBalance(tokenAddress: weth, amount: "350000000000000000"),    // 0.35 WETH
            TokenBalance(tokenAddress: usdt, amount: "1200000000"),           // 1,200 USDT
        ])

        balanceService.seedEthBalance(chainName: chain, address: IDs.primaryEth, balance: "2400000000000000000")
        balanceService.seedERC20Balances(chainName: chain, address: IDs.primaryEth, balances: [
            TokenBalance(tokenAddress: weth, amount: "500000000000000000"),
            TokenBalance(tokenAddress: usdc, amount: "1500000000"),
        ])

        balanceService.seedEthBalance(chainName: chain, address: IDs.secondaryEth, balance: "180000000000000000")
        balanceService.seedERC20Balances(chainName: chain, address: IDs.secondaryEth, balances: [])
    }

    private static func seedBroadcasters(_ broadcasterState: BroadcasterState) {
        broadcasterState.connectionStatus = "Connected"
        broadcasterState.peerStats = PeerStats(
            started: true,
            meshPeerCount: 14,
            pubSubPeerCount: 9,
            chainName: Chain.ethereum.rawValue
        )
        let weth = Token.weth.address(on: .ethereum)!
        let usdc = Token.usdc.address(on: .ethereum)!
        let now = Date().timeIntervalSince1970
        broadcasterState.broadcasters = [
            BroadcasterInfo(
                railgunAddress: "0zk1q8m2y0v6dr8tjw5fqv0wkpfqj7c0vu2x4ww5ks0c4l3r9wm0fve9rv7j6fe3z53lugc08rj0cy0sa3v59ekju5tn5jx5avcdr8je7wxq8fdax8u4kfp0",
                tokenAddress: weth,
                feePerUnitGas: "12500000000",
                expiration: now + 600,
                feesID: "fees-1",
                availableWallets: 4,
                relayAdapt: "0xrelay1",
                reliability: 0.99
            ),
            BroadcasterInfo(
                railgunAddress: "0zk1q9k2qj3l4m5n6o7p8q9r0s1t2u3v4w5x6y7z8a9b0c1d2e3f4g5h6i7j8k9l0a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v",
                tokenAddress: weth,
                feePerUnitGas: "13800000000",
                expiration: now + 580,
                feesID: "fees-2",
                availableWallets: 3,
                relayAdapt: "0xrelay2",
                reliability: 0.95
            ),
            BroadcasterInfo(
                railgunAddress: "0zk1qaaabbbcccdddeeefffggghhhiiijjjkkklllmmmnnnooopppqqqrrrssstttuuuvvvwwwxxxyyyzzz0001112223334445556667778889",
                tokenAddress: usdc,
                feePerUnitGas: "11200000000",
                expiration: now + 720,
                feesID: "fees-3",
                availableWallets: 6,
                relayAdapt: "0xrelay3",
                reliability: 0.98
            ),
            BroadcasterInfo(
                railgunAddress: "0zk1q1z2y3x4w5v6u7t8s9r0q1p2o3n4m5l6k7j8i9h0g1f2e3d4c5b6a7z8y9x0w1v2u3t4s5r6q7p8o9n0m1l2k3j4i5h6g7f8e9d0c1b",
                tokenAddress: usdc,
                feePerUnitGas: "14000000000",
                expiration: now + 320,
                feesID: "fees-4",
                availableWallets: 2,
                relayAdapt: "0xrelay4",
                reliability: 0.92
            ),
            BroadcasterInfo(
                railgunAddress: "0zk1qzzzyyyxxxwwwvvvuuuttttssssrrrqqqpppoooonnnnmmmlllkkkjjjiiihhhggggffffeeedddccccbbbaaa999888777666555444333222111000",
                tokenAddress: weth,
                feePerUnitGas: "12000000000",
                expiration: now + 900,
                feesID: "fees-5",
                availableWallets: 5,
                relayAdapt: "0xrelay5",
                reliability: 1.0
            ),
            BroadcasterInfo(
                railgunAddress: "0zk1q3l4m5n6o7p8q9r0s1t2u3v4w5x6y7z8a9b0c1d2e3f4g5h6i7j8k9l0aabbccddeeffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz1122334455",
                tokenAddress: weth,
                feePerUnitGas: "12700000000",
                expiration: now + 480,
                feesID: "fees-6",
                availableWallets: 3,
                relayAdapt: "0xrelay6",
                reliability: 0.97
            ),
        ]
    }

    /// Seed a "Missing POI proof" row plus a "Verifying shield" row so the
    /// pending-POI section between public and private balances shows a
    /// Submit-able pending state.
    private static func seedPendingPOI(balanceService: BalanceService, walletID: String) {
        let chain = Chain.ethereum.rawValue
        let weth = Token.weth
        let usdc = Token.usdc
        let entries: [NativeScannerService.PendingPOI] = [
            NativeScannerService.PendingPOI(
                id: "\(chain):demoshieldpending01:weth",
                txid: "badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0",
                bucket: .shieldPending,
                isShield: true,
                token: weth,
                tokenDisplay: weth.address(on: .ethereum) ?? "WETH",
                amountRaw: "120000000000000000",  // 0.12 WETH
                blockNumber: 19_499_812
            ),
            NativeScannerService.PendingPOI(
                id: "\(chain):demoproofsubmitted02:usdc",
                txid: "decafbaddecafbaddecafbaddecafbaddecafbaddecafbaddecafbaddecafbad",
                bucket: .proofSubmitted,
                isShield: false,
                token: usdc,
                tokenDisplay: usdc.address(on: .ethereum) ?? "USDC",
                amountRaw: "180000000",  // 180 USDC
                blockNumber: 19_499_640
            ),
        ]
        balanceService.nativeScanner.seedPendingPOIEntries(
            chainName: chain, walletID: walletID, entries: entries
        )
        balanceService.nativeScanner.seedPOIStatus(chainName: chain, .succeeded(at: Date()))
    }

    private static func seedTransactions(_ store: TransactionStore, includeRecentUnshield: Bool = false) {
        let chain = Chain.ethereum.rawValue
        let now = Date()
        var txs: [Transaction] = [
            Transaction(
                id: "demo-tx-1",
                action: .shield,
                chainName: chain,
                txHash: "0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
                timestamp: now.addingTimeInterval(-86400 * 3),
                tokenSymbol: "WETH",
                amount: "0.5",
                fromWalletID: IDs.primaryWallet,
                fromAddress: IDs.primaryEth,
                toAddress: IDs.primaryRailgun
            ),
            Transaction(
                id: "demo-tx-2",
                action: .privateSend,
                chainName: chain,
                txHash: "0xCAFEBABECAFEBABECAFEBABECAFEBABECAFEBABECAFEBABECAFEBABECAFEBABE",
                timestamp: now.addingTimeInterval(-86400 * 1 - 7200),
                tokenSymbol: "USDC",
                amount: "250.00",
                fromWalletID: IDs.primaryWallet,
                fromAddress: IDs.primaryRailgun,
                toAddress: IDs.secondaryRailgun
            ),
            Transaction(
                id: "demo-tx-3",
                action: .shield,
                chainName: chain,
                txHash: "0xF00DBABEF00DBABEF00DBABEF00DBABEF00DBABEF00DBABEF00DBABEF00DBABE",
                timestamp: now.addingTimeInterval(-3600 * 6),
                tokenSymbol: "USDC",
                amount: "1500.00",
                fromWalletID: IDs.primaryWallet,
                fromAddress: IDs.primaryEth,
                toAddress: IDs.primaryRailgun
            ),
        ]
        if includeRecentUnshield {
            txs.insert(Transaction(
                id: "demo-tx-recent-unshield",
                action: .unshield,
                chainName: chain,
                txHash: "0xFEEDFACEFEEDFACEFEEDFACEFEEDFACEFEEDFACEFEEDFACEFEEDFACEFEEDFACE",
                timestamp: now.addingTimeInterval(-300),
                tokenSymbol: "WETH",
                amount: "0.25",
                fromWalletID: IDs.primaryWallet,
                fromAddress: IDs.primaryRailgun,
                toAddress: IDs.primaryEth
            ), at: 0)
        }
        store.setForPreview(txs)
    }
}

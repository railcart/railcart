//
//  AccountDetailView.swift
//  railcart
//
//  Detail view for a single wallet account.
//  Split into public address (top) and private zk address (bottom) sections.
//

import SwiftUI

struct AccountDetailView: View {
    @Environment(\.balanceService) private var balanceService
    @Environment(\.walletService) private var walletService
    @Environment(WalletState.self) private var walletState
    @Environment(NetworkState.self) private var network
    @Environment(TransactionStore.self) private var transactionStore

    let accountID: String

    @State private var isEditingName = false
    @FocusState private var nameFieldFocused: Bool

    // Shield/unshield sheets keyed by token symbol (so SwiftUI re-presents on change).
    @State private var shieldToken: Token?
    @State private var unshieldToken: Token?

    // Public balances
    @State private var ethBalance: String?
    @State private var publicTokenBalances: [String: String] = [:]
    @State private var isLoadingPublic = false

    // Private balances (read from BalanceService cache; scanning is centralized)
    private var privateTokenBalances: [TokenBalance] {
        guard let account, let balanceService else { return [] }
        return balanceService.cachedPrivateBalances(
            chainName: network.selectedChain.rawValue, walletID: account.id
        ) ?? []
    }

    private var account: Account? {
        walletState.account(byID: accountID)
    }

    private var unlocked: Account.Unlocked? {
        walletState.unlockedKeys[accountID]
    }

    var body: some View {
        if let account, let unlocked {
            accountView(account: account, unlocked: unlocked)
        } else if account != nil, walletState.step != .ready {
            // Account exists in persisted list but engine/wallet hasn't finished
            // loading yet — show a progress state instead of a scary error.
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading wallet…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Account Not Found",
                systemImage: "exclamationmark.triangle",
                description: Text("This account could not be loaded.")
            )
        }
    }

    private func accountView(account: Account, unlocked: Account.Unlocked) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                walletHeader(account: account)

                VStack(spacing: 20) {
                    PublicBalanceSection(
                        ethAddress: unlocked.ethAddress,
                        ethBalance: ethBalance,
                        tokenBalances: publicTokenBalances,
                        chain: network.selectedChain,
                        isLoading: isLoadingPublic,
                        onRefresh: { Task { await loadPublicBalances(address: unlocked.ethAddress) } },
                        onShield: { token in shieldToken = token }
                    )

                    let pendingShields = pendingShieldTransactions(for: account)
                    if !pendingShields.isEmpty {
                        PendingShieldView(transactions: pendingShields)
                    }

                    PrivateBalanceSection(
                        railgunAddress: account.railgunAddress,
                        tokenBalances: privateTokenBalances,
                        chain: network.selectedChain,
                        isScanning: balanceService?.isScanning ?? false,
                        scanStep: balanceService?.scanStep,
                        scanProgress: balanceService?.scanProgress ?? 0,
                        errorMessage: nil,
                        onRefresh: { Task { await refreshPrivateBalances() } },
                        onUnshield: { token in unshieldToken = token }
                    )
                }
                .padding(20)
            }
        }
        .frame(minWidth: 500, minHeight: 500)
        .task {
            try? await network.ensureProviderLoaded(for: network.selectedChain, using: walletService)
            await loadPublicBalances(address: unlocked.ethAddress)
        }
        .onChange(of: network.selectedChain) {
            ethBalance = nil
            publicTokenBalances = [:]
            Task {
                try? await network.ensureProviderLoaded(for: network.selectedChain, using: walletService)
                await loadPublicBalances(address: unlocked.ethAddress)
            }
        }
        .sheet(item: $shieldToken) { token in
            ShieldSheet(token: token, account: account, unlocked: unlocked)
        }
        .sheet(item: $unshieldToken) { token in
            UnshieldSheet(token: token, account: account, unlocked: unlocked)
        }
    }

    // MARK: - Header

    private func walletHeader(account: Account) -> some View {
        HStack(spacing: 8) {
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

            Spacer()

            Text(network.selectedChain.displayName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(network.selectedChain.isTestnet ? .orange.opacity(0.15) : .blue.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(network.selectedChain.isTestnet ? .orange : .blue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Data Loading

    private func loadPublicBalances(address: String) async {
        guard let balanceService else { return }
        isLoadingPublic = true
        defer { isLoadingPublic = false }

        do {
            ethBalance = try await balanceService.getEthBalance(
                chainName: network.selectedChain.rawValue, address: address
            )
        } catch {
            AppLogger.shared.log("error", "Failed to load ETH balance: \(error.localizedDescription)")
        }

        let tokenAddresses = Token.supported.compactMap { $0.address(on: network.selectedChain) }
        guard !tokenAddresses.isEmpty else { return }
        do {
            let balances = try await balanceService.getERC20Balances(
                chainName: network.selectedChain.rawValue,
                address: address,
                tokenAddresses: tokenAddresses
            )
            for b in balances {
                publicTokenBalances[b.tokenAddress.lowercased()] = b.amount
            }
        } catch {
            AppLogger.shared.log("error", "Failed to load ERC-20 balances: \(error.localizedDescription)")
        }
    }

    /// Force-refresh private balances for all wallets (invalidates cache first).
    private func refreshPrivateBalances() async {
        guard let balanceService else { return }
        let chain = network.selectedChain.rawValue
        balanceService.invalidateAllPrivateBalances(chainName: chain)
        let walletIDs = walletState.accounts.map(\.id)
        await balanceService.scanAllPrivateBalances(chainName: chain, walletIDs: walletIDs)
    }

    /// Shield transactions from this account on the current chain within the last hour.
    private func pendingShieldTransactions(for account: Account) -> [Transaction] {
        let cutoff = Date().addingTimeInterval(-3600)
        return transactionStore.transactions.filter { tx in
            tx.action == .shield
                && tx.chainName == network.selectedChain.rawValue
                && tx.fromAccountID == account.id
                && tx.timestamp > cutoff
        }
    }
}

// MARK: - Preview

#Preview("Account Detail") {
    @Previewable @State var walletState = {
        let state = WalletState()
        state.setAccountsForPreview([
            Account(
                id: "preview-wallet-id",
                derivationIndex: 0,
                railgunAddress: "0zk1qy0v9cdm2pjash8wnfrz7xq5az62a3rjq7m4c9kfkxwcegrcc5t6rcpxgy08",
                name: "Preview Wallet"
            )
        ])
        state.unlockedKeys["preview-wallet-id"] = Account.Unlocked(
            ethAddress: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18",
            ethPrivateKey: ""
        )
        state.setStep(.ready)
        return state
    }()

    let txStore = {
        let store = TransactionStore()
        store.setForPreview([
            Transaction(
                id: "preview-tx",
                action: .shield,
                chainName: "sepolia",
                txHash: "0xabc123def456789012345678901234567890abcdef",
                timestamp: Date().addingTimeInterval(-185),
                tokenSymbol: "ETH",
                amount: "0.5",
                fromAccountID: "preview-wallet-id",
                fromAddress: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18",
                toAddress: "0zk1qy0v9cdm2pjash8wnfrz7xq5az62a3rjq7m4c9kfkxwcegrcc5t6rcpxgy08"
            )
        ])
        return store
    }()

    let mockService = MockWalletService()

    AccountDetailView(accountID: "preview-wallet-id")
        .environment(walletState)
        .environment(NetworkState())
        .environment(txStore)
        .environment(\.walletService, mockService)
        .environment(\.balanceService, BalanceService(walletService: mockService))
        .frame(width: 580, height: 700)
}

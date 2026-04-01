//
//  MockWalletService.swift
//  railcart
//
//  Mock wallet service for SwiftUI previews and tests.
//  Returns static sample data without touching Keychain, NodeBridge, or network.
//

import Foundation

struct MockWalletService: WalletServiceProtocol {
    var ethBalance: String = "1500000000000000000"  // 1.5 ETH

    /// Sample amounts by token symbol for public balances.
    var publicAmounts: [String: String] = [
        "WETH": "500000000000000000",   // 0.5
        "USDC": "2500000000",           // 2500
        "USDT": "1000000000",           // 1000
    ]

    /// Sample amounts by token symbol for private balances.
    var privateAmounts: [String: String] = [
        "WETH": "250000000000000000",   // 0.25
        "USDC": "750000000",            // 750
    ]

    func validateMnemonic(_ mnemonic: String) async throws -> MnemonicValidation { MnemonicValidation(valid: true, error: nil) }
    func generateMnemonic() async throws -> String { "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about" }
    func deriveEncryptionKey(password: String, salt: String) async throws -> String { "mock-encryption-key" }
    func getBlockNumber(chainName: String) async throws -> Int { 20_000_000 }
    func createWallet(encryptionKey: String, mnemonic: String, derivationIndex: Int, creationBlockNumbers: [String: Int]) async throws -> WalletInfoResponse {
        WalletInfoResponse(id: "mock-id", railgunAddress: "0zk...", ethAddress: "0x000...", ethPrivateKey: "", derivationIndex: derivationIndex)
    }
    func loadWallet(encryptionKey: String, walletID: String, derivationIndex: Int) async throws -> WalletInfoResponse {
        WalletInfoResponse(id: walletID, railgunAddress: "0zk...", ethAddress: "0x000...", ethPrivateKey: "", derivationIndex: derivationIndex)
    }
    func getRailgunAddress(walletID: String) async throws -> String { "0zk..." }
    func getWalletMnemonic(encryptionKey: String, walletID: String) async throws -> String { "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about" }
    func deriveEthereumKey(encryptionKey: String, walletID: String, index: Int) async throws -> DerivedEthKey {
        DerivedEthKey(address: "0x000...", privateKey: "", index: index)
    }

    func getEthBalance(chainName: String, address: String) async throws -> String { ethBalance }

    func getERC20Balances(chainName: String, address: String, tokenAddresses: [String]) async throws -> [TokenBalance] {
        tokenAddresses.compactMap { addr in
            guard let token = Token.supported.first(where: { t in
                t.addresses.values.contains(where: { $0.lowercased() == addr.lowercased() })
            }),
            let amount = publicAmounts[token.symbol] else { return nil }
            return TokenBalance(tokenAddress: addr, amount: amount)
        }
    }

    func shieldBaseToken(chainName: String, railgunAddress: String, amount: String, privateKey: String) async throws -> String { "0xmocktxhash" }
    func unshieldBaseToken(chainName: String, walletID: String, encryptionKey: String, toAddress: String, amount: String, privateKey: String, onProofProgress: @escaping @Sendable (Double) -> Void) async throws -> String { "0xmocktxhash" }

    func scanBalances(chainName: String, walletIDs: [String]) async throws {}
    func fullRescan(chainName: String, walletIDs: [String]) async throws {}

    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance] {
        try await scanAndGetBalances(chainName: chainName, walletID: walletID)
    }

    func scanAndGetBalances(chainName: String, walletID: String) async throws -> [TokenBalance] {
        let chain: Chain = chainName == "sepolia" ? .sepolia : .ethereum
        return Token.supported.compactMap { token in
            guard let addr = token.address(on: chain),
                  let amount = privateAmounts[token.symbol] else { return nil }
            return TokenBalance(tokenAddress: addr, amount: amount)
        }
    }

    func loadChainProvider(chainName: String, providerUrl: String) async throws {}
}

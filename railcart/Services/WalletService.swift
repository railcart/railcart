//
//  WalletService.swift
//  railcart
//
//  Protocol defining all RAILGUN wallet operations.
//  Views depend on this protocol; the live implementation talks to NodeBridge.
//

import Foundation
import SwiftUI
import RailcartChain
import BigInt

// MARK: - Environment Key

private struct WalletServiceKey: EnvironmentKey {
    @MainActor static let defaultValue: any WalletServiceProtocol = UnimplementedWalletService()
}

extension EnvironmentValues {
    var walletService: any WalletServiceProtocol {
        get { self[WalletServiceKey.self] }
        set { self[WalletServiceKey.self] = newValue }
    }
}

/// Crashes on any call — ensures we always inject a real implementation.
struct UnimplementedWalletService: WalletServiceProtocol {
    func validateMnemonic(_ mnemonic: String) async throws -> MnemonicValidation { fatalError() }
    func generateMnemonic() async throws -> String { fatalError() }
    func deriveEncryptionKey(password: String, salt: String) async throws -> String { fatalError() }
    func getBlockNumber(chainName: String) async throws -> Int { fatalError() }
    func createWallet(encryptionKey: String, mnemonic: String, derivationIndex: Int, creationBlockNumbers: [String: Int]) async throws -> WalletInfoResponse { fatalError() }
    func loadWallet(encryptionKey: String, walletID: String, derivationIndex: Int) async throws -> WalletInfoResponse { fatalError() }
    func getRailgunAddress(walletID: String) async throws -> String { fatalError() }
    func getWalletMnemonic(encryptionKey: String, walletID: String) async throws -> String { fatalError() }
    func deriveEthereumKey(encryptionKey: String, walletID: String, index: Int) async throws -> DerivedEthKey { fatalError() }
    func getEthBalance(chainName: String, address: String) async throws -> String { fatalError() }
    func getERC20Balances(chainName: String, address: String, tokenAddresses: [String]) async throws -> [TokenBalance] { fatalError() }
    func shieldBaseToken(chainName: String, railgunAddress: String, amount: String, privateKey: String) async throws -> String { fatalError() }
    func unshieldBaseToken(chainName: String, walletID: String, encryptionKey: String, toAddress: String, amount: String, privateKey: String, onProofProgress: @escaping @Sendable (Double) -> Void) async throws -> String { fatalError() }
    func scanBalances(chainName: String, walletIDs: [String]) async throws { fatalError() }
    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance] { fatalError() }
    func scanAndGetBalances(chainName: String, walletID: String) async throws -> [TokenBalance] { fatalError() }
    func loadChainProvider(chainName: String, providerUrl: String) async throws { fatalError() }
}

// MARK: - Response Types

struct MnemonicValidation: Decodable, Sendable {
    let valid: Bool
    let error: String?
}

struct MnemonicResponse: Decodable, Sendable {
    let mnemonic: String
}

struct EncryptionKeyResponse: Decodable, Sendable {
    let encryptionKey: String
}

struct WalletInfoResponse: Decodable, Sendable {
    let id: String
    let railgunAddress: String
    let ethAddress: String
    let ethPrivateKey: String
    let derivationIndex: Int
}

struct DerivedEthKey: Decodable, Sendable {
    let address: String
    let privateKey: String
    let index: Int
}

struct EthBalanceResponse: Decodable, Sendable {
    let balance: String
    let address: String?
}

struct RailgunAddressResponse: Decodable, Sendable {
    let railgunAddress: String
}

struct TransactionData: Decodable, Sendable {
    let to: String
    let data: String
    let value: String
    let gasLimit: String?
    let chainId: String?
}

struct ShieldTransactionResponse: Decodable, Sendable {
    let transaction: TransactionData
}


struct TokenBalance: Decodable, Identifiable, Sendable {
    let tokenAddress: String
    let amount: String

    var id: String { tokenAddress }

    var shortTokenAddress: String {
        if tokenAddress.count > 12 {
            return String(tokenAddress.prefix(6)) + "..." + String(tokenAddress.suffix(4))
        }
        return tokenAddress
    }

    var formattedAmount: String {
        guard let wei = Double(amount) else { return amount }
        let eth = wei / 1e18
        if eth == 0 { return "0" }
        return String(format: "%.6f", eth)
    }
}

struct BalancesResponse: Decodable, Sendable {
    let balances: [TokenBalance]
}

struct ERC20BalancesResponse: Decodable, Sendable {
    let balances: [TokenBalance]
}

// MARK: - Protocol

@MainActor
protocol WalletServiceProtocol: Sendable {
    // Wallet management
    func validateMnemonic(_ mnemonic: String) async throws -> MnemonicValidation
    func generateMnemonic() async throws -> String
    func deriveEncryptionKey(password: String, salt: String) async throws -> String
    func getBlockNumber(chainName: String) async throws -> Int
    func createWallet(encryptionKey: String, mnemonic: String, derivationIndex: Int, creationBlockNumbers: [String: Int]) async throws -> WalletInfoResponse
    func loadWallet(encryptionKey: String, walletID: String, derivationIndex: Int) async throws -> WalletInfoResponse
    func getRailgunAddress(walletID: String) async throws -> String
    func getWalletMnemonic(encryptionKey: String, walletID: String) async throws -> String
    func deriveEthereumKey(encryptionKey: String, walletID: String, index: Int) async throws -> DerivedEthKey

    // ETH balance
    func getEthBalance(chainName: String, address: String) async throws -> String

    // Shield / Unshield
    func shieldBaseToken(
        chainName: String,
        railgunAddress: String,
        amount: String,
        privateKey: String
    ) async throws -> String // txHash

    func unshieldBaseToken(
        chainName: String,
        walletID: String,
        encryptionKey: String,
        toAddress: String,
        amount: String,
        privateKey: String,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String // txHash

    // Balances
    func scanBalances(chainName: String, walletIDs: [String]) async throws
    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance]
    func scanAndGetBalances(chainName: String, walletID: String) async throws -> [TokenBalance]
    func getERC20Balances(chainName: String, address: String, tokenAddresses: [String]) async throws -> [TokenBalance]

    // Settings
    func loadChainProvider(chainName: String, providerUrl: String) async throws
}

// MARK: - Live Implementation

@MainActor
final class LiveWalletService: WalletServiceProtocol {
    let bridge: NodeBridge
    private var rpcClients: [String: RPCClient] = [:]

    init(bridge: NodeBridge) {
        self.bridge = bridge
        // Pre-create RPC clients from config
        for (chain, url) in Config.chainProviders where !url.isEmpty {
            if let rpcURL = URL(string: url) {
                rpcClients[chain] = RPCClient(url: rpcURL)
            }
        }
    }

    private func rpc(for chainName: String) throws -> RPCClient {
        guard let client = rpcClients[chainName] else {
            throw ChainError.signingFailed("No RPC provider for chain: \(chainName)")
        }
        return client
    }

    /// Sign and broadcast a transaction in Swift. Private key never leaves this process.
    private func signAndSend(
        chainName: String,
        privateKey: String,
        txData: TransactionData
    ) async throws -> String {
        let signer = try TransactionSigner(privateKey: privateKey)
        let fromAddress = try signer.address()
        let client = try rpc(for: chainName)

        let nonce = try await client.getNonce(address: fromAddress)
        let chainId = try await client.getChainId()

        let toAddress = try RailcartChain.Address(txData.to)
        let value = BigUInt(txData.value) ?? 0
        let calldata = Data(hexString: txData.data) ?? Data()

        let gasLimit: BigUInt
        if let gl = txData.gasLimit, let parsed = BigUInt(gl) {
            gasLimit = parsed
        } else {
            gasLimit = try await client.estimateGas(to: toAddress, data: calldata, value: value)
        }

        // Determine gas pricing
        let gasPrice: UnsignedTransaction.GasPrice
        let feeData = try await client.getFeeData()
        if feeData.baseFee > 0 {
            // EIP-1559
            let maxPriority = feeData.maxPriorityFee
            let maxFee = feeData.baseFee * 2 + maxPriority
            gasPrice = .eip1559(maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriority)
        } else {
            let gp = try await client.getGasPrice()
            gasPrice = .legacy(gasPrice: gp)
        }

        let tx = UnsignedTransaction(
            chainId: chainId,
            nonce: nonce,
            to: toAddress,
            value: value,
            data: calldata,
            gasLimit: gasLimit,
            gasPrice: gasPrice
        )

        let signed = try signer.sign(tx)
        let txHash = try await client.sendRawTransaction(signed)
        return txHash
    }

    func validateMnemonic(_ mnemonic: String) async throws -> MnemonicValidation {
        try await bridge.call("validateMnemonic", params: [
            "mnemonic": mnemonic,
        ], as: MnemonicValidation.self)
    }

    func generateMnemonic() async throws -> String {
        let result = try await bridge.call("generateMnemonic", as: MnemonicResponse.self)
        return result.mnemonic
    }

    func deriveEncryptionKey(password: String, salt: String) async throws -> String {
        let result = try await bridge.call("deriveEncryptionKey", params: [
            "password": password,
            "salt": salt,
        ], as: EncryptionKeyResponse.self)
        return result.encryptionKey
    }

    func getBlockNumber(chainName: String) async throws -> Int {
        struct BlockNumberResponse: Decodable { let blockNumber: Int }
        let result = try await bridge.call("getBlockNumber", params: [
            "chainName": chainName,
        ], as: BlockNumberResponse.self)
        return result.blockNumber
    }

    func createWallet(encryptionKey: String, mnemonic: String, derivationIndex: Int, creationBlockNumbers: [String: Int]) async throws -> WalletInfoResponse {
        try await bridge.call("createWallet", params: [
            "encryptionKey": encryptionKey,
            "mnemonic": mnemonic,
            "derivationIndex": derivationIndex,
            "creationBlockNumbers": creationBlockNumbers,
        ], as: WalletInfoResponse.self)
    }

    func loadWallet(encryptionKey: String, walletID: String, derivationIndex: Int) async throws -> WalletInfoResponse {
        try await bridge.call("loadWallet", params: [
            "encryptionKey": encryptionKey,
            "railgunWalletID": walletID,
            "derivationIndex": derivationIndex,
        ], as: WalletInfoResponse.self)
    }

    func getRailgunAddress(walletID: String) async throws -> String {
        let result = try await bridge.call("getRailgunAddress", params: [
            "railgunWalletID": walletID,
        ], as: RailgunAddressResponse.self)
        return result.railgunAddress
    }

    func getWalletMnemonic(encryptionKey: String, walletID: String) async throws -> String {
        struct MnemonicResult: Decodable { let mnemonic: String }
        let result = try await bridge.call("getWalletMnemonic", params: [
            "encryptionKey": encryptionKey,
            "railgunWalletID": walletID,
        ], as: MnemonicResult.self)
        return result.mnemonic
    }

    func deriveEthereumKey(encryptionKey: String, walletID: String, index: Int) async throws -> DerivedEthKey {
        try await bridge.call("deriveEthereumKey", params: [
            "encryptionKey": encryptionKey,
            "railgunWalletID": walletID,
            "index": index,
        ], as: DerivedEthKey.self)
    }

    func getEthBalance(chainName: String, address: String) async throws -> String {
        let result = try await bridge.call("getEthBalance", params: [
            "chainName": chainName,
            "address": address,
        ], as: EthBalanceResponse.self)
        return result.balance
    }

    func getERC20Balances(chainName: String, address: String, tokenAddresses: [String]) async throws -> [TokenBalance] {
        let result = try await bridge.call("getERC20Balances", params: [
            "chainName": chainName,
            "address": address,
            "tokenAddresses": tokenAddresses,
        ], as: ERC20BalancesResponse.self)
        return result.balances
    }

    func shieldBaseToken(
        chainName: String,
        railgunAddress: String,
        amount: String,
        privateKey: String
    ) async throws -> String {
        let shieldResult = try await bridge.call("shieldBaseToken", params: [
            "chainName": chainName,
            "railgunAddress": railgunAddress,
            "amount": amount,
        ], as: ShieldTransactionResponse.self)

        return try await signAndSend(
            chainName: chainName,
            privateKey: privateKey,
            txData: shieldResult.transaction
        )
    }

    func unshieldBaseToken(
        chainName: String,
        walletID: String,
        encryptionKey: String,
        toAddress: String,
        amount: String,
        privateKey: String,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        // Listen for proof progress events
        bridge.onEvent("proofProgress") { data in
            if let dict = data as? [String: Any],
               let progress = dict["progress"] as? Double {
                onProofProgress(min(max(progress, 0), 1))
            }
        }

        // Step 1: Generate ZK proof
        let _ = try await bridge.callRaw("generateUnshieldBaseTokenProof", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "encryptionKey": encryptionKey,
            "publicWalletAddress": toAddress,
            "amount": amount,
        ], timeout: .seconds(300))

        // Step 2: Populate proved transaction
        let unshieldResult = try await bridge.call("populateUnshieldBaseToken", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "publicWalletAddress": toAddress,
            "amount": amount,
        ], as: ShieldTransactionResponse.self)

        // Step 3: Sign and send in Swift (private key never leaves this process)
        return try await signAndSend(
            chainName: chainName,
            privateKey: privateKey,
            txData: unshieldResult.transaction
        )
    }

    func scanBalances(chainName: String, walletIDs: [String]) async throws {
        // Pass all wallet IDs so the SDK scans the merkletree once for all wallets.
        // If empty, the SDK scans for all loaded wallets.
        var params: [String: any Sendable] = ["chainName": chainName]
        if !walletIDs.isEmpty {
            params["railgunWalletIDs"] = walletIDs
        }
        let _ = try await bridge.callRaw("scanBalances", params: params, timeout: .seconds(120))
    }

    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance] {
        let result = try await bridge.call("getBalances", params: [
            "railgunWalletID": walletID,
            "chainName": chainName,
        ], as: BalancesResponse.self)
        return result.balances
    }

    func scanAndGetBalances(chainName: String, walletID: String) async throws -> [TokenBalance] {
        try await scanBalances(chainName: chainName, walletIDs: [walletID])
        return try await getPrivateBalances(chainName: chainName, walletID: walletID)
    }

    func loadChainProvider(chainName: String, providerUrl: String) async throws {
        let _ = try await bridge.callRaw("loadChainProvider", params: [
            "chainName": chainName,
            "providerUrl": providerUrl,
        ])
    }
}

//
//  WalletService.swift
//  railcart
//
//  Protocol defining all RAILGUN wallet operations.
//  Views depend on this protocol; the live implementation talks to NodeBridge.
//

import Foundation
import SwiftUI
import RailcartCrypto
import BigInt
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
    func getERC20Allowance(chainName: String, tokenAddress: String, ownerAddress: String) async throws -> String { fatalError() }
    func approveERC20ForShield(chainName: String, tokenAddress: String, amount: String?, privateKey: String) async throws -> String { fatalError() }
    func shieldERC20(chainName: String, railgunAddress: String, tokenAddress: String, amount: String, privateKey: String) async throws -> String { fatalError() }
    func unshieldBaseToken(chainName: String, walletID: String, encryptionKey: String, toAddress: String, amount: String, privateKey: String, onProofProgress: @escaping @Sendable (Double) -> Void) async throws -> String { fatalError() }
    func scanBalances(chainName: String, walletIDs: [String]) async throws { fatalError() }
    func fullRescan(chainName: String, walletIDs: [String]) async throws { fatalError() }
    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance] { fatalError() }
    func scanAndGetBalances(chainName: String, walletID: String) async throws -> [TokenBalance] { fatalError() }
    func estimateBroadcasterFee(chainName: String, walletID: String, encryptionKey: String, toAddress: String, amount: String, feePerUnitGas: String) async throws -> BroadcasterFeeEstimate { fatalError() }
    func unshieldBaseTokenViaBroadcaster(chainName: String, walletID: String, encryptionKey: String, toAddress: String, amount: String, broadcaster: BroadcasterInfo, feeEstimate: BroadcasterFeeEstimate, onStep: @escaping @Sendable (BroadcasterUnshieldStep) -> Void, onProofProgress: @escaping @Sendable (Double) -> Void) async throws -> String { fatalError() }
    func unshieldERC20(chainName: String, walletID: String, encryptionKey: String, toAddress: String, tokenAddress: String, amount: String, privateKey: String, onProofProgress: @escaping @Sendable (Double) -> Void) async throws -> String { fatalError() }
    func estimateBroadcasterFeeERC20(chainName: String, walletID: String, encryptionKey: String, toAddress: String, tokenAddress: String, amount: String, feePerUnitGas: String, feeTokenAddress: String) async throws -> BroadcasterFeeEstimate { fatalError() }
    func unshieldERC20ViaBroadcaster(chainName: String, walletID: String, encryptionKey: String, toAddress: String, tokenAddress: String, amount: String, broadcaster: BroadcasterInfo, feeEstimate: BroadcasterFeeEstimate, feeTokenAddress: String, onStep: @escaping @Sendable (BroadcasterUnshieldStep) -> Void, onProofProgress: @escaping @Sendable (Double) -> Void) async throws -> String { fatalError() }
    func waitForTransaction(chainName: String, txHash: String) async throws { fatalError() }
    func loadChainProvider(chainName: String, providerUrl: String) async throws { fatalError() }
    func loadChainProviderFromRemoteConfig(chainName: String) async throws { fatalError() }
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

struct BroadcasterFeeEstimate: Decodable, Sendable {
    let gasEstimate: String
    let broadcasterFeeAmount: String
    let gasPrice: String
}

enum BroadcasterUnshieldStep: Sendable {
    case estimatingGas
    case generatingProof
    case populatingTransaction
    case submittingToBroadcaster
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

    func getERC20Allowance(
        chainName: String,
        tokenAddress: String,
        ownerAddress: String
    ) async throws -> String // allowance in wei

    func approveERC20ForShield(
        chainName: String,
        tokenAddress: String,
        amount: String?,
        privateKey: String
    ) async throws -> String // txHash

    func shieldERC20(
        chainName: String,
        railgunAddress: String,
        tokenAddress: String,
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
    func fullRescan(chainName: String, walletIDs: [String]) async throws
    func getPrivateBalances(chainName: String, walletID: String) async throws -> [TokenBalance]
    func scanAndGetBalances(chainName: String, walletID: String) async throws -> [TokenBalance]
    func getERC20Balances(chainName: String, address: String, tokenAddresses: [String]) async throws -> [TokenBalance]

    // Broadcaster unshield
    func estimateBroadcasterFee(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, amount: String, feePerUnitGas: String
    ) async throws -> BroadcasterFeeEstimate

    func unshieldBaseTokenViaBroadcaster(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, amount: String, broadcaster: BroadcasterInfo,
        feeEstimate: BroadcasterFeeEstimate,
        onStep: @escaping @Sendable (BroadcasterUnshieldStep) -> Void,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String

    // ERC-20 unshield
    func unshieldERC20(
        chainName: String,
        walletID: String,
        encryptionKey: String,
        toAddress: String,
        tokenAddress: String,
        amount: String,
        privateKey: String,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String

    func estimateBroadcasterFeeERC20(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, tokenAddress: String, amount: String,
        feePerUnitGas: String, feeTokenAddress: String
    ) async throws -> BroadcasterFeeEstimate

    func unshieldERC20ViaBroadcaster(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, tokenAddress: String, amount: String,
        broadcaster: BroadcasterInfo, feeEstimate: BroadcasterFeeEstimate,
        feeTokenAddress: String,
        onStep: @escaping @Sendable (BroadcasterUnshieldStep) -> Void,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String

    // Transaction confirmation
    func waitForTransaction(chainName: String, txHash: String) async throws

    // Settings
    func loadChainProvider(chainName: String, providerUrl: String) async throws
    func loadChainProviderFromRemoteConfig(chainName: String) async throws
}

// MARK: - Live Implementation

@MainActor
final class LiveWalletService: WalletServiceProtocol {
    let bridge: NodeBridge
    private var rpcClients: [String: RPCClient] = [:]

    init(bridge: NodeBridge) {
        self.bridge = bridge

        // Keep Swift-side RPCClient in sync when Node.js rotates providers.
        bridge.onEvent("providerRotated") { [weak self] data in
            guard let dict = data as? [String: Any],
                  let chainName = dict["chainName"] as? String,
                  let urlString = dict["providerUrl"] as? String,
                  let url = URL(string: urlString)
            else { return }
            Task { @MainActor [weak self] in
                self?.rpcClients[chainName] = RPCClient(url: url)
                AppLogger.shared.log("rpc", "Provider rotated for \(chainName): \(urlString)")
            }
        }
    }

    private func rpc(for chainName: String) throws -> RPCClient {
        guard let client = rpcClients[chainName] else {
            throw ChainError.signingFailed("No RPC provider for chain: \(chainName)")
        }
        return client
    }

    /// Format an RPC error with provider URL and HTTP status for logging.
    private func describeRPCError(_ error: Error) -> String {
        if case RPCError.httpError(let code, let method, let url) = error {
            return "http=\(code) method=\(method) url=\(url)"
        }
        if case RPCError.rpcError(let code, let message) = error {
            return "rpc_code=\(code) \(message)"
        }
        if let urlError = error as? URLError {
            return "url_error=\(urlError.code.rawValue) \(urlError.localizedDescription)"
        }
        return error.localizedDescription
    }

    /// Whether an error looks like a provider connectivity issue (vs. a logic error).
    private func isProviderError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case RPCError.httpError(let code, _, _) = error {
            return [429, 502, 503, 504].contains(code)
        }
        return false
    }

    /// Ask Node.js to rotate to the next available RPC for this chain.
    /// Updates the local RPCClient on success (via the providerRotated event).
    private func rotateProvider(for chainName: String) async -> Bool {
        do {
            let _ = try await bridge.callRaw("rotateChainProvider", params: [
                "chainName": chainName,
            ])
            return true
        } catch {
            AppLogger.shared.log("rpc", "Provider rotation failed for \(chainName): \(error.localizedDescription)")
            return false
        }
    }

    /// Sign and broadcast a transaction in Swift. Private key never leaves this process.
    /// On provider failure, rotates to the next RPC and retries once.
    private func signAndSend(
        chainName: String,
        privateKey: String,
        txData: TransactionData
    ) async throws -> String {
        do {
            return try await executeSignAndSend(chainName: chainName, privateKey: privateKey, txData: txData)
        } catch {
            let url = (try? rpc(for: chainName))?.url.absoluteString ?? "(unknown)"
            let detail = describeRPCError(error)
            guard isProviderError(error) else {
                AppLogger.shared.log("rpc", "signAndSend failed (not retryable) provider=\(url) \(detail)")
                throw error
            }
            AppLogger.shared.log("rpc", "signAndSend provider error provider=\(url) \(detail) — rotating")
            guard await rotateProvider(for: chainName) else { throw error }
            return try await executeSignAndSend(chainName: chainName, privateKey: privateKey, txData: txData)
        }
    }

    private func executeSignAndSend(
        chainName: String,
        privateKey: String,
        txData: TransactionData
    ) async throws -> String {
        let logger = AppLogger.shared
        let signer = try TransactionSigner(privateKey: privateKey)
        let fromAddress = try signer.address()
        let client = try rpc(for: chainName)

        logger.log("rpc", "signAndSend: \(chainName) via \(client.url.host ?? client.url.absoluteString) from=\(fromAddress.hex)")

        let balance = try await client.getBalance(address: fromAddress)
        logger.log("rpc", "from balance=\(balance) wei")

        let nonce = try await client.getNonce(address: fromAddress)
        let chainId = try await client.getChainId()
        logger.log("rpc", "nonce=\(nonce) chainId=\(chainId)")

        let toAddress = try RailcartChain.Address(txData.to)
        let value = BigUInt(txData.value) ?? 0
        let calldata = Data(hexString: txData.data) ?? Data()

        let gasLimit: BigUInt
        if let gl = txData.gasLimit, let parsed = BigUInt(gl) {
            gasLimit = parsed
        } else {
            gasLimit = try await client.estimateGas(from: fromAddress, to: toAddress, data: calldata, value: value)
        }
        logger.log("rpc", "gasLimit=\(gasLimit)")

        // Determine gas pricing
        let gasPrice: UnsignedTransaction.GasPrice
        let feeData = try await client.getFeeData()
        if feeData.baseFee > 0 {
            // EIP-1559
            let maxPriority = feeData.maxPriorityFee
            let maxFee = feeData.baseFee * 2 + maxPriority
            gasPrice = .eip1559(maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriority)
            logger.log("rpc", "EIP-1559 baseFee=\(feeData.baseFee) maxFee=\(maxFee) maxPriority=\(maxPriority)")
        } else {
            let gp = try await client.getGasPrice()
            gasPrice = .legacy(gasPrice: gp)
            logger.log("rpc", "legacy gasPrice=\(gp)")
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
        do {
            let txHash = try await client.sendRawTransaction(signed)
            logger.log("rpc", "tx sent: \(txHash)")
            return txHash
        } catch {
            logger.log("error", "sendRawTransaction failed: \(error.localizedDescription)")
            throw error
        }
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

    func getERC20Allowance(
        chainName: String,
        tokenAddress: String,
        ownerAddress: String
    ) async throws -> String {
        struct AllowanceResponse: Decodable { let allowance: String }
        let result = try await bridge.call("getERC20Allowance", params: [
            "chainName": chainName,
            "tokenAddress": tokenAddress,
            "ownerAddress": ownerAddress,
        ], as: AllowanceResponse.self)
        return result.allowance
    }

    func approveERC20ForShield(
        chainName: String,
        tokenAddress: String,
        amount: String?,
        privateKey: String
    ) async throws -> String {
        var params: [String: Any] = [
            "chainName": chainName,
            "tokenAddress": tokenAddress,
        ]
        if let amount { params["amount"] = amount }
        let approveResult = try await bridge.call("approveERC20ForShield",
            params: params, as: ShieldTransactionResponse.self)
        return try await signAndSend(
            chainName: chainName,
            privateKey: privateKey,
            txData: approveResult.transaction
        )
    }

    func shieldERC20(
        chainName: String,
        railgunAddress: String,
        tokenAddress: String,
        amount: String,
        privateKey: String
    ) async throws -> String {
        let shieldResult = try await bridge.call("shieldERC20", params: [
            "chainName": chainName,
            "railgunAddress": railgunAddress,
            "tokenAddress": tokenAddress,
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

    func fullRescan(chainName: String, walletIDs: [String]) async throws {
        var params: [String: any Sendable] = ["chainName": chainName]
        if !walletIDs.isEmpty {
            params["railgunWalletIDs"] = walletIDs
        }
        let _ = try await bridge.callRaw("fullRescan", params: params, timeout: .seconds(600))
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

    func waitForTransaction(chainName: String, txHash: String) async throws {
        let client = try rpc(for: chainName)
        try await client.waitForReceipt(txHash: txHash)
    }

    func loadChainProvider(chainName: String, providerUrl: String) async throws {
        let _ = try await bridge.callRaw("loadChainProvider", params: [
            "chainName": chainName,
            "providerUrl": providerUrl,
        ])
        if let url = URL(string: providerUrl) {
            rpcClients[chainName] = RPCClient(url: url)
        }
    }

    func loadChainProviderFromRemoteConfig(chainName: String) async throws {
        struct RemoteConfigProviderResponse: Decodable {
            let providerUrls: [String]?
        }
        let result = try await bridge.call("loadChainProviderFromRemoteConfig", params: [
            "chainName": chainName,
        ], as: RemoteConfigProviderResponse.self)
        if let firstUrl = result.providerUrls?.first, let url = URL(string: firstUrl) {
            rpcClients[chainName] = RPCClient(url: url)
        }
    }

    // MARK: - Native Unshield (uses Swift scanner, bypasses SDK scanning)

    func unshieldWithNativeScanner(
        chainName: String,
        walletID: String,
        encryptionKey: String,
        toAddress: String,
        tokenAddress: String,
        amount: String,
        privateKey: String,
        nativeScanner: NativeScannerService,
        onProofProgress: @escaping @Sendable (Double) -> Void,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Listen for proof progress events from the bridge
        bridge.onEvent("proofProgress") { data in
            if let dict = data as? [String: Any],
               let progress = dict["progress"] as? Double {
                onProofProgress(min(max(progress, 0), 1))
            }
        }

        // Assemble proof inputs from native scanner
        guard let scanner = nativeScanner.getScanner(walletID: walletID, chainName: chainName) else {
            throw NSError(domain: "NativeUnshield", code: 1, userInfo: [NSLocalizedDescriptionKey: "Scanner not initialized"])
        }

        onStatusUpdate?("Building merkle tree...")
        scanner.onTreeBuildProgress = { @Sendable (inserted, total) in
            onStatusUpdate?("Building merkle tree: \(inserted)/\(total)")
        }

        let proofInputs = try await Task.detached(priority: .userInitiated) {
            try ProofAssembler.assembleUnshield(
                scanner: scanner,
                tokenAddress: tokenAddress,
                amount: BigUInt(amount) ?? 0
            )
        }.value

        onStatusUpdate?("Generating zero-knowledge proof...")

        // Build bridge params from proof inputs + wallet/chain info
        var bridgeParams = proofInputs.toBridgeJSON()
        bridgeParams["chainName"] = chainName
        bridgeParams["railgunWalletID"] = walletID
        bridgeParams["encryptionKey"] = encryptionKey
        bridgeParams["toAddress"] = toAddress
        bridgeParams["sendWithPublicWallet"] = true

        // Generate proof and build transaction in one bridge call (no cache handoff)
        let result = try await bridge.call(
            "generateUnshieldProofNative",
            params: bridgeParams,
            as: ShieldTransactionResponse.self,
            timeout: .seconds(300)
        )

        return try await signAndSend(
            chainName: chainName,
            privateKey: privateKey,
            txData: result.transaction
        )
    }

    // MARK: - Broadcaster Unshield

    func estimateBroadcasterFee(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, amount: String, feePerUnitGas: String
    ) async throws -> BroadcasterFeeEstimate {
        try await bridge.call("gasEstimateForBroadcasterUnshield", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "encryptionKey": encryptionKey,
            "publicWalletAddress": toAddress,
            "amount": amount,
            "feePerUnitGas": feePerUnitGas,
        ], as: BroadcasterFeeEstimate.self)
    }

    func unshieldBaseTokenViaBroadcaster(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, amount: String, broadcaster: BroadcasterInfo,
        feeEstimate: BroadcasterFeeEstimate,
        onStep: @escaping @Sendable (BroadcasterUnshieldStep) -> Void,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        // Listen for proof progress events
        bridge.onEvent("proofProgress") { data in
            if let dict = data as? [String: Any],
               let progress = dict["progress"] as? Double {
                onProofProgress(min(max(progress, 0), 1))
            }
        }

        let wrappedAddress = Token.weth.address(on: Chain(rawValue: chainName) ?? .ethereum) ?? ""

        // Step 1: Generate ZK proof with broadcaster fee
        onStep(.generatingProof)
        let _ = try await bridge.callRaw("generateBroadcasterUnshieldProof", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "encryptionKey": encryptionKey,
            "publicWalletAddress": toAddress,
            "amount": amount,
            "broadcasterFeeTokenAddress": wrappedAddress,
            "broadcasterFeeAmount": feeEstimate.broadcasterFeeAmount,
            "broadcasterRailgunAddress": broadcaster.railgunAddress,
            "overallBatchMinGasPrice": feeEstimate.gasPrice,
        ], timeout: .seconds(300))

        // Step 2: Populate proved transaction
        onStep(.populatingTransaction)
        let populateResult = try await bridge.callRaw("populateBroadcasterUnshield", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "publicWalletAddress": toAddress,
            "amount": amount,
            "broadcasterFeeTokenAddress": wrappedAddress,
            "broadcasterFeeAmount": feeEstimate.broadcasterFeeAmount,
            "broadcasterRailgunAddress": broadcaster.railgunAddress,
            "overallBatchMinGasPrice": feeEstimate.gasPrice,
        ])

        guard let resultDict = populateResult as? [String: Any],
              let txDict = resultDict["transaction"] as? [String: Any],
              let to = txDict["to"] as? String,
              let data = txDict["data"] as? String,
              let nullifiers = resultDict["nullifiers"] as? [String],
              let pois = resultDict["preTransactionPOIsPerTxidLeafPerList"]
        else {
            throw NodeBridgeError.decodingError("Failed to decode broadcaster populate response")
        }

        // Step 3: Submit to broadcaster via Waku
        onStep(.submittingToBroadcaster)
        struct SubmitResponse: Decodable { let txHash: String }
        let submitResult = try await bridge.call("submitBroadcasterTransaction", params: [
            "chainName": chainName,
            "to": to,
            "data": data,
            "broadcasterRailgunAddress": broadcaster.railgunAddress,
            "broadcasterFeesID": broadcaster.feesID,
            "nullifiers": nullifiers,
            "overallBatchMinGasPrice": feeEstimate.gasPrice,
            "useRelayAdapt": true,
            "preTransactionPOIsPerTxidLeafPerList": pois,
        ] as [String: any Sendable], as: SubmitResponse.self, timeout: .seconds(120))

        return submitResult.txHash
    }

    // MARK: - ERC-20 Unshield

    func unshieldERC20(
        chainName: String,
        walletID: String,
        encryptionKey: String,
        toAddress: String,
        tokenAddress: String,
        amount: String,
        privateKey: String,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        bridge.onEvent("proofProgress") { data in
            if let dict = data as? [String: Any],
               let progress = dict["progress"] as? Double {
                onProofProgress(min(max(progress, 0), 1))
            }
        }

        let _ = try await bridge.callRaw("generateUnshieldERC20Proof", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "encryptionKey": encryptionKey,
            "toAddress": toAddress,
            "tokenAddress": tokenAddress,
            "amount": amount,
        ], timeout: .seconds(300))

        let unshieldResult = try await bridge.call("populateUnshieldERC20", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "toAddress": toAddress,
            "tokenAddress": tokenAddress,
            "amount": amount,
        ], as: ShieldTransactionResponse.self)

        return try await signAndSend(
            chainName: chainName,
            privateKey: privateKey,
            txData: unshieldResult.transaction
        )
    }

    func estimateBroadcasterFeeERC20(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, tokenAddress: String, amount: String,
        feePerUnitGas: String, feeTokenAddress: String
    ) async throws -> BroadcasterFeeEstimate {
        try await bridge.call("gasEstimateForBroadcasterUnshieldERC20", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "encryptionKey": encryptionKey,
            "toAddress": toAddress,
            "tokenAddress": tokenAddress,
            "amount": amount,
            "feePerUnitGas": feePerUnitGas,
            "feeTokenAddress": feeTokenAddress,
        ], as: BroadcasterFeeEstimate.self)
    }

    func unshieldERC20ViaBroadcaster(
        chainName: String, walletID: String, encryptionKey: String,
        toAddress: String, tokenAddress: String, amount: String,
        broadcaster: BroadcasterInfo, feeEstimate: BroadcasterFeeEstimate,
        feeTokenAddress: String,
        onStep: @escaping @Sendable (BroadcasterUnshieldStep) -> Void,
        onProofProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        bridge.onEvent("proofProgress") { data in
            if let dict = data as? [String: Any],
               let progress = dict["progress"] as? Double {
                onProofProgress(min(max(progress, 0), 1))
            }
        }

        // Step 1: Generate ZK proof with broadcaster fee
        onStep(.generatingProof)
        let _ = try await bridge.callRaw("generateBroadcasterUnshieldERC20Proof", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "encryptionKey": encryptionKey,
            "toAddress": toAddress,
            "tokenAddress": tokenAddress,
            "amount": amount,
            "broadcasterFeeTokenAddress": feeTokenAddress,
            "broadcasterFeeAmount": feeEstimate.broadcasterFeeAmount,
            "broadcasterRailgunAddress": broadcaster.railgunAddress,
            "overallBatchMinGasPrice": feeEstimate.gasPrice,
        ], timeout: .seconds(300))

        // Step 2: Populate proved transaction
        onStep(.populatingTransaction)
        let populateResult = try await bridge.callRaw("populateBroadcasterUnshieldERC20", params: [
            "chainName": chainName,
            "railgunWalletID": walletID,
            "toAddress": toAddress,
            "tokenAddress": tokenAddress,
            "amount": amount,
            "broadcasterFeeTokenAddress": feeTokenAddress,
            "broadcasterFeeAmount": feeEstimate.broadcasterFeeAmount,
            "broadcasterRailgunAddress": broadcaster.railgunAddress,
            "overallBatchMinGasPrice": feeEstimate.gasPrice,
        ])

        guard let resultDict = populateResult as? [String: Any],
              let txDict = resultDict["transaction"] as? [String: Any],
              let to = txDict["to"] as? String,
              let data = txDict["data"] as? String,
              let nullifiers = resultDict["nullifiers"] as? [String],
              let pois = resultDict["preTransactionPOIsPerTxidLeafPerList"]
        else {
            throw NodeBridgeError.decodingError("Failed to decode broadcaster populate response")
        }

        // Step 3: Submit to broadcaster via Waku
        onStep(.submittingToBroadcaster)
        struct SubmitResponse: Decodable { let txHash: String }
        let submitResult = try await bridge.call("submitBroadcasterTransaction", params: [
            "chainName": chainName,
            "to": to,
            "data": data,
            "broadcasterRailgunAddress": broadcaster.railgunAddress,
            "broadcasterFeesID": broadcaster.feesID,
            "nullifiers": nullifiers,
            "overallBatchMinGasPrice": feeEstimate.gasPrice,
            "useRelayAdapt": true,
            "preTransactionPOIsPerTxidLeafPerList": pois,
        ] as [String: any Sendable], as: SubmitResponse.self, timeout: .seconds(120))

        return submitResult.txHash
    }
}

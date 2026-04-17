import Foundation
import BigInt

/// Minimal Ethereum JSON-RPC client for transaction-related calls.
public struct RPCClient: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(url: String) throws {
        guard let u = URL(string: url) else {
            throw RPCError.invalidURL(url)
        }
        self.url = u
    }

    /// Get the nonce (transaction count) for an address.
    public func getNonce(address: Address) async throws -> BigUInt {
        let result: String = try await call("eth_getTransactionCount", params: [address.hex, "pending"])
        return try decodeHexUInt(result)
    }

    /// Get the current gas price (legacy).
    public func getGasPrice() async throws -> BigUInt {
        let result: String = try await call("eth_gasPrice", params: [String]())
        return try decodeHexUInt(result)
    }

    /// Get EIP-1559 fee data.
    public func getFeeData() async throws -> (baseFee: BigUInt, maxPriorityFee: BigUInt) {
        // Get latest block for baseFeePerGas
        struct Params: Encodable {
            let block: String
            let fullTx: Bool
            func encode(to encoder: any Encoder) throws {
                var c = encoder.unkeyedContainer()
                try c.encode(block)
                try c.encode(fullTx)
            }
        }
        let block: BlockResult = try await call(
            "eth_getBlockByNumber",
            params: Params(block: "latest", fullTx: false)
        )
        let baseFee = try decodeHexUInt(block.baseFeePerGas ?? "0x0")
        let priorityFee = try decodeHexUInt("0x3b9aca00") // 1 gwei default
        return (baseFee, priorityFee)
    }

    /// Estimate gas for a transaction.
    public func estimateGas(from: Address, to: Address, data: Data, value: BigUInt) async throws -> BigUInt {
        let params: [String: String] = [
            "from": from.hex,
            "to": to.hex,
            "data": "0x" + data.hexString,
            "value": "0x" + String(value, radix: 16),
        ]
        let result: String = try await call("eth_estimateGas", params: [params])
        return try decodeHexUInt(result)
    }

    /// Get the balance of an address.
    public func getBalance(address: Address) async throws -> BigUInt {
        let result: String = try await call("eth_getBalance", params: [address.hex, "latest"])
        return try decodeHexUInt(result)
    }

    /// Send a signed raw transaction. Returns the transaction hash.
    public func sendRawTransaction(_ signedTx: SignedTransaction) async throws -> String {
        try await call("eth_sendRawTransaction", params: [signedTx.hex])
    }

    /// Poll until a transaction is mined. Returns once `eth_getTransactionReceipt`
    /// returns a non-null result, or throws after `timeout` seconds.
    public func waitForReceipt(txHash: String, timeout: TimeInterval = 120, pollInterval: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let receipt: TransactionReceipt? = try? await callOptional("eth_getTransactionReceipt", params: [txHash])
            if receipt != nil { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw RPCError.receiptTimeout(txHash)
    }

    /// Get the chain ID.
    public func getChainId() async throws -> BigUInt {
        let result: String = try await call("eth_chainId", params: [String]())
        return try decodeHexUInt(result)
    }

    // MARK: - Private

    /// Like `call` but returns nil when the RPC result is JSON `null`.
    private func callOptional<P: Encodable, R: Decodable>(_ method: String, params: P) async throws -> R? {
        let body = JSONRPCRequest(method: method, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RPCError.httpError(http.statusCode, method: method, url: url.host ?? url.absoluteString)
        }

        let rpcResponse = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: data)
        if let error = rpcResponse.error {
            throw RPCError.rpcError(code: error.code, message: error.message)
        }
        return rpcResponse.result
    }

    private func call<P: Encodable, R: Decodable>(_ method: String, params: P) async throws -> R {
        let body = JSONRPCRequest(method: method, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RPCError.httpError(http.statusCode, method: method, url: url.host ?? url.absoluteString)
        }

        let rpcResponse = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: data)
        if let error = rpcResponse.error {
            throw RPCError.rpcError(code: error.code, message: error.message)
        }
        guard let result = rpcResponse.result else {
            throw RPCError.noResult
        }
        return result
    }

    private func decodeHexUInt(_ hex: String) throws -> BigUInt {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let value = BigUInt(clean, radix: 16) else {
            throw RPCError.invalidHex(hex)
        }
        return value
    }
}

// MARK: - JSON-RPC types

private struct JSONRPCRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id = 1
    let method: String
    let params: P
}

private struct JSONRPCResponse<R: Decodable>: Decodable {
    let result: R?
    let error: RPCResponseError?
}

private struct RPCResponseError: Decodable {
    let code: Int
    let message: String
}

private struct BlockResult: Decodable {
    let baseFeePerGas: String?
}

private struct TransactionReceipt: Decodable {
    let transactionHash: String
    let status: String?
}

public enum RPCError: LocalizedError, Sendable {
    case invalidURL(String)
    case httpError(Int, method: String, url: String)
    case rpcError(code: Int, message: String)
    case noResult
    case invalidHex(String)
    case receiptTimeout(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): "Invalid RPC URL: \(url)"
        case .httpError(let code, let method, let url): "HTTP \(code) from \(url) (\(method))"
        case .rpcError(_, let message): "RPC error: \(message)"
        case .noResult: "No result from RPC"
        case .invalidHex(let hex): "Invalid hex value: \(hex)"
        case .receiptTimeout(let txHash): "Transaction not confirmed after timeout: \(txHash)"
        }
    }
}

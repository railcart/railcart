import Foundation
import BigInt

/// An Ethereum address (20 bytes).
public struct Address: Sendable, Hashable {
    public let data: Data

    public init(_ hex: String) throws {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard clean.count == 40, let bytes = Data(hexString: clean) else {
            throw ChainError.invalidAddress(hex)
        }
        self.data = bytes
    }

    public init(data: Data) throws {
        guard data.count == 20 else {
            throw ChainError.invalidAddress("expected 20 bytes, got \(data.count)")
        }
        self.data = data
    }

    public var hex: String {
        "0x" + data.hexString
    }
}

/// An unsigned Ethereum transaction.
public struct UnsignedTransaction: Sendable {
    public let chainId: BigUInt
    public let nonce: BigUInt
    public let to: Address
    public let value: BigUInt
    public let data: Data
    public let gasLimit: BigUInt

    /// Gas pricing — either legacy or EIP-1559.
    public let gasPrice: GasPrice

    public enum GasPrice: Sendable {
        case legacy(gasPrice: BigUInt)
        case eip1559(maxFeePerGas: BigUInt, maxPriorityFeePerGas: BigUInt)
    }

    public init(
        chainId: BigUInt,
        nonce: BigUInt,
        to: Address,
        value: BigUInt,
        data: Data,
        gasLimit: BigUInt,
        gasPrice: GasPrice
    ) {
        self.chainId = chainId
        self.nonce = nonce
        self.to = to
        self.value = value
        self.data = data
        self.gasLimit = gasLimit
        self.gasPrice = gasPrice
    }

    /// The EIP-2718 transaction type.
    public var txType: UInt8 {
        switch gasPrice {
        case .legacy: 0
        case .eip1559: 2
        }
    }
}

/// A signed raw transaction ready for broadcast.
public struct SignedTransaction: Sendable {
    /// The raw transaction bytes (including type prefix for typed transactions).
    public let rawTransaction: Data

    /// Hex-encoded raw transaction with 0x prefix, for eth_sendRawTransaction.
    public var hex: String {
        "0x" + rawTransaction.hexString
    }

    /// Transaction hash.
    public var hash: String {
        "0x" + Keccak.hash256(rawTransaction).hexString
    }
}

public enum ChainError: LocalizedError, Sendable {
    case invalidAddress(String)
    case invalidPrivateKey
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let detail): "Invalid address: \(detail)"
        case .invalidPrivateKey: "Invalid private key"
        case .signingFailed(let detail): "Signing failed: \(detail)"
        }
    }
}

// MARK: - Hex helpers

extension Data {
    public init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import BigInt

/// Builds RLP-encoded transaction payloads for signing and broadcasting.
public enum TransactionBuilder {
    /// Compute the signing hash for a transaction.
    public static func signingHash(for tx: UnsignedTransaction) -> Data {
        switch tx.gasPrice {
        case .legacy:
            return legacySigningHash(tx)
        case .eip1559:
            return eip1559SigningHash(tx)
        }
    }

    /// Encode a signed transaction for broadcast.
    public static func encode(
        _ tx: UnsignedTransaction,
        v: BigUInt,
        r: BigUInt,
        s: BigUInt
    ) -> SignedTransaction {
        switch tx.gasPrice {
        case .legacy:
            return legacyEncode(tx, v: v, r: r, s: s)
        case .eip1559:
            return eip1559Encode(tx, v: v, r: r, s: s)
        }
    }

    // MARK: - Legacy (Type 0, EIP-155)

    private static func legacySigningHash(_ tx: UnsignedTransaction) -> Data {
        let items: [RLP.Item] = [
            .bytes(tx.nonce.rlpBytes),
            .bytes(tx.gasPrice.legacyGasPrice.rlpBytes),
            .bytes(tx.gasLimit.rlpBytes),
            .bytes(tx.to.data),
            .bytes(tx.value.rlpBytes),
            .bytes(tx.data),
            .bytes(tx.chainId.rlpBytes),
            .bytes(Data()),  // 0
            .bytes(Data()),  // 0
        ]
        let encoded = RLP.encode(.list(items))
        return Keccak.hash256(encoded)
    }

    private static func legacyEncode(
        _ tx: UnsignedTransaction,
        v: BigUInt,
        r: BigUInt,
        s: BigUInt
    ) -> SignedTransaction {
        let items: [RLP.Item] = [
            .bytes(tx.nonce.rlpBytes),
            .bytes(tx.gasPrice.legacyGasPrice.rlpBytes),
            .bytes(tx.gasLimit.rlpBytes),
            .bytes(tx.to.data),
            .bytes(tx.value.rlpBytes),
            .bytes(tx.data),
            .bytes(v.rlpBytes),
            .bytes(r.rlpBytes),
            .bytes(s.rlpBytes),
        ]
        return SignedTransaction(rawTransaction: RLP.encode(.list(items)))
    }

    // MARK: - EIP-1559 (Type 2)

    private static func eip1559SigningHash(_ tx: UnsignedTransaction) -> Data {
        let items: [RLP.Item] = [
            .bytes(tx.chainId.rlpBytes),
            .bytes(tx.nonce.rlpBytes),
            .bytes(tx.gasPrice.maxPriorityFeePerGas.rlpBytes),
            .bytes(tx.gasPrice.maxFeePerGas.rlpBytes),
            .bytes(tx.gasLimit.rlpBytes),
            .bytes(tx.to.data),
            .bytes(tx.value.rlpBytes),
            .bytes(tx.data),
            .list([]),  // accessList (empty)
        ]
        let payload = RLP.encode(.list(items))
        return Keccak.hash256(Data([0x02]) + payload)
    }

    private static func eip1559Encode(
        _ tx: UnsignedTransaction,
        v: BigUInt,
        r: BigUInt,
        s: BigUInt
    ) -> SignedTransaction {
        let items: [RLP.Item] = [
            .bytes(tx.chainId.rlpBytes),
            .bytes(tx.nonce.rlpBytes),
            .bytes(tx.gasPrice.maxPriorityFeePerGas.rlpBytes),
            .bytes(tx.gasPrice.maxFeePerGas.rlpBytes),
            .bytes(tx.gasLimit.rlpBytes),
            .bytes(tx.to.data),
            .bytes(tx.value.rlpBytes),
            .bytes(tx.data),
            .list([]),  // accessList
            .bytes(v.rlpBytes),
            .bytes(r.rlpBytes),
            .bytes(s.rlpBytes),
        ]
        let payload = RLP.encode(.list(items))
        return SignedTransaction(rawTransaction: Data([0x02]) + payload)
    }
}

// MARK: - BigUInt helpers

extension BigUInt {
    /// Encode as minimal big-endian bytes for RLP (no leading zeros, 0 → empty data).
    var rlpBytes: Data {
        if self == 0 { return Data() }
        let bytes = serialize()
        // serialize() returns big-endian with possible leading zeros
        if let firstNonZero = bytes.firstIndex(where: { $0 != 0 }) {
            return Data(bytes[firstNonZero...])
        }
        return Data()
    }
}

extension UnsignedTransaction.GasPrice {
    var legacyGasPrice: BigUInt {
        switch self {
        case .legacy(let gp): gp
        case .eip1559: 0
        }
    }

    var maxFeePerGas: BigUInt {
        switch self {
        case .legacy: 0
        case .eip1559(let mfpg, _): mfpg
        }
    }

    var maxPriorityFeePerGas: BigUInt {
        switch self {
        case .legacy: 0
        case .eip1559(_, let mpfpg): mpfpg
        }
    }
}

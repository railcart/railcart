import Foundation
import BigInt
import P256K

/// Signs Ethereum transactions using secp256k1.
public struct TransactionSigner: Sendable {
    private let privateKeyData: Data

    public init(privateKey: String) throws {
        let clean = privateKey.hasPrefix("0x") ? String(privateKey.dropFirst(2)) : privateKey
        guard let data = Data(hexString: clean), data.count == 32 else {
            throw ChainError.invalidPrivateKey
        }
        self.privateKeyData = data
    }

    public init(privateKey: Data) throws {
        guard privateKey.count == 32 else {
            throw ChainError.invalidPrivateKey
        }
        self.privateKeyData = privateKey
    }

    /// Sign a transaction and return the signed raw transaction.
    public func sign(_ tx: UnsignedTransaction) throws -> SignedTransaction {
        let hash = TransactionBuilder.signingHash(for: tx)
        let (r, s, recoveryId) = try ecdsaSign(hash: hash)

        let v: BigUInt
        switch tx.gasPrice {
        case .legacy:
            // EIP-155: v = recoveryId + chainId * 2 + 35
            v = BigUInt(recoveryId) + tx.chainId * 2 + 35
        case .eip1559:
            // EIP-1559: v = recoveryId (0 or 1)
            v = BigUInt(recoveryId)
        }

        return TransactionBuilder.encode(tx, v: v, r: r, s: s)
    }

    /// Derive the Ethereum address from this private key.
    public func address() throws -> Address {
        let key = try P256K.Signing.PrivateKey(dataRepresentation: privateKeyData)
        // Uncompressed public key is 65 bytes (0x04 prefix + 64 bytes)
        let pubKey = key.publicKey.uncompressedRepresentation
        // Ethereum address = last 20 bytes of keccak256(pubkey[1:])
        let hash = Keccak.hash256(Data(pubKey.dropFirst()))
        return try Address(data: hash.suffix(20))
    }

    // MARK: - Private

    private func ecdsaSign(hash: Data) throws -> (r: BigUInt, s: BigUInt, recoveryId: Int) {
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKeyData)

        let signature = try key.signature(for: hash)
        let compact = try signature.compactRepresentation

        let r = BigUInt(Data(compact.signature.prefix(32)))
        let s = BigUInt(Data(compact.signature.suffix(32)))
        let recoveryId = Int(compact.recoveryId)

        return (r, s, recoveryId)
    }
}

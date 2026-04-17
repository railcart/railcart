import Testing
import Foundation
import BigInt
@testable import EVMKit
import P256K

@Suite struct TransactionSignerTests {
    // Well-known test vector: a private key with a known address
    let testPrivateKey = "4c0883a69102937d6231471b5dbb6204fe512961708279f35e2e39f3e6e12218"
    let testAddress = "0xe96c706c1fe25aa02da96791e11d689cdc645f62"

    @Test func deriveAddress() throws {
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let address = try signer.address()
        #expect(address.hex == testAddress)
    }

    @Test func signLegacyTransaction() throws {
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let tx = UnsignedTransaction(
            chainId: 1,
            nonce: 0,
            to: try Address("0x3535353535353535353535353535353535353535"),
            value: BigUInt("1000000000000000000"), // 1 ETH
            data: Data(),
            gasLimit: 21000,
            gasPrice: .legacy(gasPrice: BigUInt("20000000000")) // 20 gwei
        )
        let signed = try signer.sign(tx)
        // Should produce valid signed tx bytes starting with RLP list prefix
        #expect(signed.rawTransaction.count > 0)
        #expect(signed.hash.hasPrefix("0x"))
        #expect(signed.hash.count == 66) // 0x + 64 hex chars
    }

    @Test func signEIP1559Transaction() throws {
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let tx = UnsignedTransaction(
            chainId: 11155111, // Sepolia
            nonce: 0,
            to: try Address("0x3535353535353535353535353535353535353535"),
            value: BigUInt("1000000000000000"), // 0.001 ETH
            data: Data(),
            gasLimit: 21000,
            gasPrice: .eip1559(
                maxFeePerGas: BigUInt("30000000000"),
                maxPriorityFeePerGas: BigUInt("1000000000")
            )
        )
        let signed = try signer.sign(tx)
        // Type 2 transactions start with 0x02
        #expect(signed.rawTransaction[0] == 0x02)
        #expect(signed.hash.hasPrefix("0x"))
    }

    // MARK: - Signature recovery tests

    @Test func legacySignatureRecoversToCorrectAddress() throws {
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let expectedAddress = try signer.address()

        let tx = UnsignedTransaction(
            chainId: 1,
            nonce: 0,
            to: try Address("0x3535353535353535353535353535353535353535"),
            value: BigUInt("1000000000000000000"),
            data: Data(),
            gasLimit: 21000,
            gasPrice: .legacy(gasPrice: BigUInt("20000000000"))
        )

        let signingHash = TransactionBuilder.signingHash(for: tx)
        let signed = try signer.sign(tx)
        let recovered = try recoverAddress(from: signed, signingHash: signingHash, txType: .legacy(chainId: 1))
        #expect(recovered.hex == expectedAddress.hex)
    }

    @Test func eip1559SignatureRecoversToCorrectAddress() throws {
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let expectedAddress = try signer.address()

        let tx = UnsignedTransaction(
            chainId: 11155111,
            nonce: 0,
            to: try Address("0x3535353535353535353535353535353535353535"),
            value: BigUInt("1000000000000000"),
            data: Data(),
            gasLimit: 21000,
            gasPrice: .eip1559(
                maxFeePerGas: BigUInt("30000000000"),
                maxPriorityFeePerGas: BigUInt("1000000000")
            )
        )

        let signingHash = TransactionBuilder.signingHash(for: tx)
        let signed = try signer.sign(tx)
        let recovered = try recoverAddress(from: signed, signingHash: signingHash, txType: .eip1559)
        #expect(recovered.hex == expectedAddress.hex)
    }

    @Test func eip1559WithLargeCalldataRecoversCorrectly() throws {
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let expectedAddress = try signer.address()

        // Simulate shield-like calldata (> 500 bytes)
        var calldata = Data(count: 580)
        for i in 0..<calldata.count { calldata[i] = UInt8(i % 256) }

        let tx = UnsignedTransaction(
            chainId: 11155111,
            nonce: 0,
            to: try Address("0x3535353535353535353535353535353535353535"),
            value: BigUInt("10000000000000000"), // 0.01 ETH
            data: calldata,
            gasLimit: 850000,
            gasPrice: .eip1559(
                maxFeePerGas: BigUInt("8930664772"),
                maxPriorityFeePerGas: BigUInt("1000000000")
            )
        )

        let signingHash = TransactionBuilder.signingHash(for: tx)
        let signed = try signer.sign(tx)
        let recovered = try recoverAddress(from: signed, signingHash: signingHash, txType: .eip1559)
        #expect(recovered.hex == expectedAddress.hex)
    }

    @Test func multipleSignaturesAllRecoverCorrectly() throws {
        // Sign many transactions to exercise both low-s and (would-be) high-s paths
        let signer = try TransactionSigner(privateKey: testPrivateKey)
        let expectedAddress = try signer.address()

        for nonce in 0..<20 {
            let tx = UnsignedTransaction(
                chainId: 11155111,
                nonce: BigUInt(nonce),
                to: try Address("0x3535353535353535353535353535353535353535"),
                value: BigUInt("1000000000000000"),
                data: Data(),
                gasLimit: 21000,
                gasPrice: .eip1559(
                    maxFeePerGas: BigUInt("30000000000"),
                    maxPriorityFeePerGas: BigUInt("1000000000")
                )
            )
            let signingHash = TransactionBuilder.signingHash(for: tx)
            let signed = try signer.sign(tx)
            let recovered = try recoverAddress(from: signed, signingHash: signingHash, txType: .eip1559)
            #expect(recovered.hex == expectedAddress.hex, "Recovery failed at nonce \(nonce)")
        }
    }

    @Test func invalidPrivateKeyThrows() throws {
        #expect(throws: ChainError.self) {
            try TransactionSigner(privateKey: "not a valid key")
        }
    }

    @Test func shortPrivateKeyThrows() throws {
        #expect(throws: ChainError.self) {
            try TransactionSigner(privateKey: "0x1234")
        }
    }

    // MARK: - Helpers

    private enum TxType {
        case legacy(chainId: BigUInt)
        case eip1559
    }

    /// Recover the Ethereum address from a signed transaction using ecrecover.
    private func recoverAddress(
        from signed: SignedTransaction,
        signingHash: Data,
        txType: TxType
    ) throws -> Address {
        // Extract v, r, s from the signed transaction by re-signing and comparing
        // Instead, we use P256K's recovery to go from (hash, signature) -> public key -> address
        let raw = signed.rawTransaction

        // For EIP-1559: raw = [0x02] + RLP([..., v, r, s])
        // For legacy: raw = RLP([..., v, r, s])
        let rlpData: Data
        let vOffset: Int // number of fields before v in the RLP list

        switch txType {
        case .legacy:
            rlpData = raw
            vOffset = 6  // nonce, gasPrice, gasLimit, to, value, data, THEN v, r, s
        case .eip1559:
            rlpData = Data(raw.dropFirst()) // strip 0x02 prefix
            vOffset = 9  // chainId, nonce, maxPriorityFee, maxFee, gasLimit, to, value, data, accessList, THEN v, r, s
        }

        let items = try decodeRLPList(rlpData)
        let vBytes = items[vOffset]
        let rBytes = items[vOffset + 1]
        let sBytes = items[vOffset + 2]

        let v = vBytes.isEmpty ? 0 : Int(BigUInt(vBytes))
        let recoveryId: Int32
        switch txType {
        case .legacy(let chainId):
            recoveryId = Int32(v) - Int32(chainId * 2 + 35)
        case .eip1559:
            recoveryId = Int32(v)
        }

        // Reconstruct compact signature [r (32 bytes) || s (32 bytes)]
        let rPadded = Data(repeating: 0, count: 32 - rBytes.count) + rBytes
        let sPadded = Data(repeating: 0, count: 32 - sBytes.count) + sBytes
        let compactSig = rPadded + sPadded

        let recoverySig = try P256K.Recovery.ECDSASignature(
            compactRepresentation: compactSig,
            recoveryId: recoveryId
        )

        let digest = HashDigest(Array(signingHash))
        let pubKey = try P256K.Recovery.PublicKey(digest, signature: recoverySig, format: .uncompressed)
        let pubKeyData = pubKey.dataRepresentation

        // Ethereum address = last 20 bytes of keccak256(pubkey[1:])  (drop 0x04 prefix)
        let hash = Keccak.hash256(Data(pubKeyData.dropFirst()))
        return try Address(data: hash.suffix(20))
    }

    /// Minimal RLP list decoder — returns the raw bytes of each item in the top-level list.
    private func decodeRLPList(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        guard !bytes.isEmpty else { throw RLPDecodeError.empty }

        let firstByte = bytes[0]
        guard firstByte >= 0xc0 else { throw RLPDecodeError.notAList }

        let (_, listStart) = try decodeLength(bytes, offset: 0, base: 0xc0)

        var items: [Data] = []
        var pos = listStart
        while pos < bytes.count {
            let b = bytes[pos]
            if b < 0x80 {
                // Single byte
                items.append(Data([b]))
                pos += 1
            } else if b <= 0xb7 {
                // Short string: 0-55 bytes
                let len = Int(b - 0x80)
                items.append(Data(bytes[(pos + 1)..<(pos + 1 + len)]))
                pos += 1 + len
            } else if b <= 0xbf {
                // Long string
                let lenOfLen = Int(b - 0xb7)
                var len = 0
                for i in 0..<lenOfLen {
                    len = (len << 8) | Int(bytes[pos + 1 + i])
                }
                let start = pos + 1 + lenOfLen
                items.append(Data(bytes[start..<(start + len)]))
                pos = start + len
            } else if b <= 0xf7 {
                // Short list (e.g. empty accessList = 0xc0)
                let len = Int(b - 0xc0)
                // Store sub-list as raw bytes (we don't need to decode nested lists)
                items.append(Data(bytes[(pos + 1)..<(pos + 1 + len)]))
                pos += 1 + len
            } else {
                // Long list
                let lenOfLen = Int(b - 0xf7)
                var len = 0
                for i in 0..<lenOfLen {
                    len = (len << 8) | Int(bytes[pos + 1 + i])
                }
                let start = pos + 1 + lenOfLen
                items.append(Data(bytes[start..<(start + len)]))
                pos = start + len
            }
        }
        return items
    }

    private func decodeLength(_ bytes: [UInt8], offset: Int, base: UInt8) throws -> (Int, Int) {
        let b = bytes[offset]
        if b < base + 56 {
            let len = Int(b - base)
            return (len, offset + 1)
        }
        let lenOfLen = Int(b - base - 55)
        var len = 0
        for i in 0..<lenOfLen {
            len = (len << 8) | Int(bytes[offset + 1 + i])
        }
        return (len, offset + 1 + lenOfLen)
    }

    private enum RLPDecodeError: Error {
        case empty, notAList
    }
}

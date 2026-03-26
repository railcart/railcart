import Testing
import Foundation
import BigInt
@testable import RailcartChain

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
}

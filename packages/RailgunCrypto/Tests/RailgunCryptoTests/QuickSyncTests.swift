import Testing
import BigInt
import Foundation
@testable import RailgunCrypto

@Suite("Quick Sync")
struct QuickSyncTests {
    @Test("Fetch recent Ethereum commitments from subgraph")
    func fetchEthereumCommitments() async throws {
        let qs = try QuickSync(chainName: "ethereum")
        // Fetch from a recent-ish block to get a small result set
        let events = try await qs.fetchEvents(startBlock: 20_000_000)

        // Should have some commitments
        #expect(!events.commitments.isEmpty, "Expected commitments from mainnet subgraph")

        // Check first transact commitment has valid ciphertext
        let firstTransact = events.commitments.first { commitment in
            if case .transact = commitment { return true }
            return false
        }
        if case .transact(let tc) = firstTransact {
            #expect(tc.ciphertext.iv.count == 16)
            #expect(tc.ciphertext.tag.count == 16)
            #expect(!tc.ciphertext.data.isEmpty)
            #expect(tc.ciphertext.blindedSenderViewingKey.count == 32)
            #expect(tc.ciphertext.blindedReceiverViewingKey.count == 32)
            #expect(tc.blockNumber >= 20_000_000)
        }

        // Should have some nullifiers
        #expect(!events.nullifiers.isEmpty, "Expected nullifiers from mainnet subgraph")
        #expect(events.nullifiers[0].nullifier.count == 32)
    }

    @Test("Fetch Sepolia commitments from subgraph")
    func fetchSepoliaCommitments() async throws {
        let qs = try QuickSync(chainName: "sepolia")
        let events = try await qs.fetchEvents(startBlock: 0)

        // Sepolia should have at least some shield commitments
        let shields = events.commitments.filter { commitment in
            if case .shield = commitment { return true }
            return false
        }
        if let firstShield = shields.first, case .shield(let sc) = firstShield {
            #expect(sc.shieldKey.count == 32)
            #expect(sc.encryptedBundle.count == 3)
            #expect(sc.preImage.npk.count == 32)
        }
    }

    @Test("Unsupported chain throws")
    func unsupportedChain() {
        #expect(throws: QuickSyncError.self) {
            try QuickSync(chainName: "fakechain")
        }
    }
}

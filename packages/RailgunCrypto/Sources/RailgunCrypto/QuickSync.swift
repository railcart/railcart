import BigInt
import Foundation

/// Fetches RAILGUN V2 events from the quick-sync GraphQL subgraph.
public struct QuickSync: Sendable {
    /// Subgraph endpoints per chain.
    public static let endpoints: [String: String] = [
        "ethereum": "https://rail-squid.squids.live/squid-railgun-ethereum-v2/graphql",
        "bsc": "https://rail-squid.squids.live/squid-railgun-bsc-v2/graphql",
        "polygon": "https://rail-squid.squids.live/squid-railgun-polygon-v2/graphql",
        "arbitrum": "https://rail-squid.squids.live/squid-railgun-arbitrum-v2/graphql",
        "sepolia": "https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql",
    ]

    private let endpoint: URL
    private let session: URLSession

    public init(chainName: String, session: URLSession = .shared) throws {
        guard let urlString = Self.endpoints[chainName],
              let url = URL(string: urlString) else {
            throw QuickSyncError.unsupportedChain(chainName)
        }
        self.endpoint = url
        self.session = session
    }

    /// Progress callback: (fetchedSoFar, type) where type is "commitments", "nullifiers", etc.
    public var onFetchProgress: (@Sendable (Int, String) -> Void)?

    /// Fetch all events since `startBlock`, paginating through all results.
    public func fetchEvents(startBlock: Int) async throws -> ScanEvents {
        async let commitments = fetchAllCommitments(startBlock: startBlock)
        async let nullifiers = fetchAllNullifiers(startBlock: startBlock)
        async let unshields = fetchAllUnshields(startBlock: startBlock)

        return try await ScanEvents(
            commitments: commitments,
            nullifiers: nullifiers,
            unshields: unshields
        )
    }

    private static let pageSize = 10000

    // MARK: - Paginated Fetchers

    private func fetchAllCommitments(startBlock: Int) async throws -> [ScanCommitment] {
        var all = [ScanCommitment]()
        var currentBlock = startBlock
        while true {
            let page = try await fetchCommitments(startBlock: currentBlock)
            all.append(contentsOf: page)
            onFetchProgress?(all.count, "commitments")
            if page.count < Self.pageSize { break }
            // Next page: start from the last block we saw + 1
            // (may re-fetch some from the same block, deduplicated by position)
            if let lastBlock = page.last.flatMap({ commitmentBlock($0) }), lastBlock > currentBlock {
                currentBlock = lastBlock
            } else {
                break
            }
        }
        return all
    }

    private func fetchAllNullifiers(startBlock: Int) async throws -> [NullifierEvent] {
        var all = [NullifierEvent]()
        var currentBlock = startBlock
        while true {
            let page = try await fetchNullifiers(startBlock: currentBlock)
            all.append(contentsOf: page)
            onFetchProgress?(all.count, "nullifiers")
            if page.count < Self.pageSize { break }
            if let lastBlock = page.last?.blockNumber, lastBlock > currentBlock {
                currentBlock = lastBlock
            } else {
                break
            }
        }
        return all
    }

    private func fetchAllUnshields(startBlock: Int) async throws -> [UnshieldEvent] {
        var all = [UnshieldEvent]()
        var currentBlock = startBlock
        while true {
            let page = try await fetchUnshields(startBlock: currentBlock)
            all.append(contentsOf: page)
            if page.count < Self.pageSize { break }
            if let lastBlock = page.last?.blockNumber, lastBlock > currentBlock {
                currentBlock = lastBlock
            } else {
                break
            }
        }
        return all
    }

    private func commitmentBlock(_ c: ScanCommitment) -> Int {
        switch c {
        case .transact(let t): return t.blockNumber
        case .shield(let s): return s.blockNumber
        case .opaque(_, _, _, let b): return b
        }
    }

    // MARK: - Single Page Fetchers

    private func fetchCommitments(startBlock: Int) async throws -> [ScanCommitment] {
        let query = """
        query Commitments($blockNumber: BigInt = 0) {
          commitments(
            orderBy: [blockNumber_ASC, treePosition_ASC]
            where: {blockNumber_gte: $blockNumber}
            limit: 10000
          ) {
            id
            treeNumber
            batchStartTreePosition
            treePosition
            blockNumber
            transactionHash
            blockTimestamp
            commitmentType
            hash
            ... on TransactCommitment {
              ciphertext {
                id
                ciphertext {
                  id
                  iv
                  tag
                  data
                }
                blindedSenderViewingKey
                blindedReceiverViewingKey
                annotationData
                memo
              }
            }
            ... on ShieldCommitment {
              shieldKey
              fee
              encryptedBundle
              preimage {
                npk
                value
                token {
                  tokenType
                  tokenAddress
                  tokenSubID
                }
              }
            }
          }
        }
        """

        let result: GraphQLResponse<CommitmentsResult> = try await graphQL(
            query: query,
            variables: ["blockNumber": "\(startBlock)"]
        )

        return result.data.commitments.compactMap { parseCommitment($0) }
    }

    // MARK: - Nullifiers

    private func fetchNullifiers(startBlock: Int) async throws -> [NullifierEvent] {
        let query = """
        query Nullifiers($blockNumber: BigInt = 0) {
          nullifiers(
            orderBy: [blockNumber_ASC, nullifier_DESC]
            where: {blockNumber_gte: $blockNumber}
            limit: 10000
          ) {
            id
            blockNumber
            nullifier
            transactionHash
            blockTimestamp
            treeNumber
          }
        }
        """

        let result: GraphQLResponse<NullifiersResult> = try await graphQL(
            query: query,
            variables: ["blockNumber": "\(startBlock)"]
        )

        return result.data.nullifiers.map { n in
            NullifierEvent(
                nullifier: hexToBytes32(n.nullifier),
                treeNumber: n.treeNumber,
                txid: hexToBytes32(n.transactionHash),
                blockNumber: Int(n.blockNumber) ?? 0
            )
        }
    }

    // MARK: - Unshields

    private func fetchUnshields(startBlock: Int) async throws -> [UnshieldEvent] {
        let query = """
        query Unshields($blockNumber: BigInt = 0) {
          unshields(
            orderBy: [blockNumber_ASC, eventLogIndex_ASC]
            where: {blockNumber_gte: $blockNumber}
            limit: 10000
          ) {
            id
            blockNumber
            to
            transactionHash
            fee
            blockTimestamp
            amount
            eventLogIndex
            token {
              tokenType
              tokenAddress
              tokenSubID
            }
          }
        }
        """

        let result: GraphQLResponse<UnshieldsResult> = try await graphQL(
            query: query,
            variables: ["blockNumber": "\(startBlock)"]
        )

        return result.data.unshields.map { u in
            UnshieldEvent(
                txid: hexToBytes32(u.transactionHash),
                timestamp: u.blockTimestamp.flatMap { Int($0) },
                toAddress: u.to,
                tokenType: graphTokenType(u.token.tokenType),
                tokenAddress: u.token.tokenAddress,
                tokenSubID: u.token.tokenSubID ?? "0",
                amount: bigIntFromString(u.amount),
                fee: bigIntFromString(u.fee),
                blockNumber: Int(u.blockNumber) ?? 0,
                eventLogIndex: u.eventLogIndex.flatMap { Int($0) }
            )
        }
    }

    // MARK: - GraphQL transport

    private func graphQL<T: Decodable>(
        query: String,
        variables: [String: String]
    ) async throws -> GraphQLResponse<T> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "query": query,
            "variables": variables,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw QuickSyncError.httpError(http.statusCode)
        }

        return try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
    }

    // MARK: - Parsing helpers

    private func parseCommitment(_ raw: RawCommitment) -> ScanCommitment? {
        switch raw.commitmentType {
        case "TransactCommitment":
            guard let ct = raw.ciphertext else { return nil }
            guard let innerCt = ct.ciphertext else { return nil }
            return .transact(TransactCommitment(
                hash: hexToBytes32(bigIntHex(raw.hash)),
                txid: hexToBytes32(raw.transactionHash),
                blockNumber: Int(raw.blockNumber) ?? 0,
                timestamp: raw.blockTimestamp.flatMap { Int($0) },
                ciphertext: CommitmentCiphertextV2(
                    iv: hexToBytes(innerCt.iv, count: 16),
                    tag: hexToBytes(innerCt.tag, count: 16),
                    data: innerCt.data.map { hexToBytes($0, count: 32) },
                    blindedSenderViewingKey: hexToBytes32(ct.blindedSenderViewingKey ?? ""),
                    blindedReceiverViewingKey: hexToBytes32(ct.blindedReceiverViewingKey ?? ""),
                    memo: ct.memo.flatMap { Data(hexString: strip0x($0)) }
                ),
                utxoTree: raw.treeNumber,
                utxoIndex: raw.treePosition
            ))

        case "ShieldCommitment":
            guard let preimage = raw.preimage,
                  let shieldKey = raw.shieldKey,
                  let encBundle = raw.encryptedBundle else { return nil }
            return .shield(ShieldCommitment(
                hash: hexToBytes32(bigIntHex(raw.hash)),
                txid: hexToBytes32(raw.transactionHash),
                blockNumber: Int(raw.blockNumber) ?? 0,
                timestamp: raw.blockTimestamp.flatMap { Int($0) },
                preImage: ShieldPreImage(
                    npk: hexToBytes32(preimage.npk),
                    tokenType: graphTokenType(preimage.token.tokenType),
                    tokenAddress: preimage.token.tokenAddress,
                    tokenSubID: bigIntFromString(preimage.token.tokenSubID ?? "0"),
                    value: bigIntFromString(preimage.value)
                ),
                encryptedBundle: encBundle.map { hexToBytes32($0) },
                shieldKey: hexToBytes32(shieldKey),
                fee: raw.fee.flatMap { bigIntFromString($0) },
                utxoTree: raw.treeNumber,
                utxoIndex: raw.treePosition
            ))

        default:
            // Legacy or unknown commitment types — can't decrypt but need in merkle tree
            return .opaque(
                hash: hexToBytes32(bigIntHex(raw.hash)),
                utxoTree: raw.treeNumber,
                utxoIndex: raw.treePosition,
                blockNumber: Int(raw.blockNumber) ?? 0
            )
        }
    }

    private func hexToBytes32(_ hex: String) -> Data {
        hexToBytes(hex, count: 32)
    }

    private func hexToBytes(_ hex: String, count: Int) -> Data {
        let stripped = strip0x(hex)
        let padded = stripped.count < count * 2
            ? String(repeating: "0", count: count * 2 - stripped.count) + stripped
            : stripped
        return Data(hexString: String(padded.prefix(count * 2))) ?? Data(repeating: 0, count: count)
    }

    private func strip0x(_ s: String) -> String {
        s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    }

    private func bigIntHex(_ s: String) -> String {
        if let val = BigUInt(s) {
            return String(val, radix: 16)
        }
        return strip0x(s)
    }

    private func bigIntFromString(_ s: String) -> BigUInt {
        if s.hasPrefix("0x") {
            return BigUInt(String(s.dropFirst(2)), radix: 16) ?? 0
        }
        return BigUInt(s) ?? 0
    }

    private func graphTokenType(_ s: String) -> Int {
        switch s {
        case "ERC20": return 0
        case "ERC721": return 1
        case "ERC1155": return 2
        default: return 0
        }
    }
}

// MARK: - GraphQL Response Types

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T
}

private struct CommitmentsResult: Decodable {
    let commitments: [RawCommitment]
}

private struct NullifiersResult: Decodable {
    let nullifiers: [RawNullifier]
}

private struct UnshieldsResult: Decodable {
    let unshields: [RawUnshield]
}

private struct RawCommitment: Decodable {
    let treeNumber: Int
    let treePosition: Int
    let blockNumber: String
    let transactionHash: String
    let blockTimestamp: String?
    let commitmentType: String
    let hash: String
    // TransactCommitment
    let ciphertext: RawCommitmentCiphertext?
    // ShieldCommitment
    let shieldKey: String?
    let fee: String?
    let encryptedBundle: [String]?
    let preimage: RawPreimage?
}

private struct RawCommitmentCiphertext: Decodable {
    let ciphertext: RawInnerCiphertext?
    let blindedSenderViewingKey: String?
    let blindedReceiverViewingKey: String?
    let annotationData: String?
    let memo: String?
}

private struct RawInnerCiphertext: Decodable {
    let iv: String
    let tag: String
    let data: [String]
}

private struct RawPreimage: Decodable {
    let npk: String
    let value: String
    let token: RawToken
}

private struct RawToken: Decodable {
    let tokenType: String
    let tokenAddress: String
    let tokenSubID: String?
}

private struct RawNullifier: Decodable {
    let blockNumber: String
    let nullifier: String
    let transactionHash: String
    let treeNumber: Int
}

private struct RawUnshield: Decodable {
    let blockNumber: String
    let to: String
    let transactionHash: String
    let fee: String
    let blockTimestamp: String?
    let amount: String
    let eventLogIndex: String?
    let token: RawToken
}

// MARK: - Errors

public enum QuickSyncError: LocalizedError, Sendable {
    case unsupportedChain(String)
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedChain(let chain): "Unsupported chain: \(chain)"
        case .httpError(let code): "Quick-sync HTTP error: \(code)"
        }
    }
}

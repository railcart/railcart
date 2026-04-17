import Foundation

/// Status of a blinded commitment on a single POI list.
///
/// Mirrors `POIStatus` from `@railgun-community/shared-models`.
public enum POIStatus: String, Sendable, Codable {
    case valid = "Valid"
    case shieldBlocked = "ShieldBlocked"
    case proofSubmitted = "ProofSubmitted"
    case missing = "Missing"
}

/// The three kinds of blinded commitment the POI node recognizes.
public enum BlindedCommitmentType: String, Sendable, Codable {
    case shield = "Shield"
    case transact = "Transact"
    case unshield = "Unshield"
}

/// A single `(blindedCommitment, type)` pair to look up on the POI node.
public struct BlindedCommitmentQuery: Sendable, Hashable {
    public let blindedCommitment: String
    public let type: BlindedCommitmentType

    public init(blindedCommitment: String, type: BlindedCommitmentType) {
        self.blindedCommitment = blindedCommitment
        self.type = type
    }
}

/// TXID version the POI node is indexed against.
public enum TXIDVersion: String, Sendable, Codable {
    case v2PoseidonMerkle = "V2_PoseidonMerkle"
    case v3PoseidonMerkle = "V3_PoseidonMerkle"
}

/// Chain identifier as the POI node expects it (chainType + chainID, stringified).
public struct POIChain: Sendable, Hashable {
    /// EVM = 0. Mirrors `ChainType` from shared-models.
    public let type: Int
    public let id: Int

    public init(type: Int, id: Int) {
        self.type = type
        self.id = id
    }

    public static let ethereumMainnet = POIChain(type: 0, id: 1)
    public static let sepolia = POIChain(type: 0, id: 11155111)
    public static let bsc = POIChain(type: 0, id: 56)
    public static let polygon = POIChain(type: 0, id: 137)
    public static let arbitrum = POIChain(type: 0, id: 42161)
}

/// The Chainalysis OFAC list key — the only Active list in `POI_REQUIRED_LISTS`
/// at the time of writing. If this rotates upstream, update here.
public let defaultPOIListKey = "efc6ddb59c098a13fb2b618fdae94c1c3a807abc8fb1837c93620c9143ee9e88"

public enum POINodeError: LocalizedError, Sendable {
    case noNodeURLs
    case httpError(Int)
    case jsonRPCError(code: Int, message: String)
    case malformedResponse(String)
    case allNodesFailed(underlying: [Error])

    public var errorDescription: String? {
        switch self {
        case .noNodeURLs: "POI client configured with no node URLs"
        case .httpError(let code): "POI node HTTP error: \(code)"
        case .jsonRPCError(let code, let message): "POI JSON-RPC error \(code): \(message)"
        case .malformedResponse(let detail): "Malformed POI response: \(detail)"
        case .allNodesFailed(let errs): "All POI nodes failed: \(errs.map { "\($0)" }.joined(separator: "; "))"
        }
    }
}

/// Lightweight client for the RAILGUN POI aggregator JSON-RPC API.
///
/// Mirrors `POINodeRequest` from `@railgun-community/wallet`: round-robins
/// across the configured node URLs, falling back on error. The only method
/// implemented here is `ppoi_pois_per_list` — it's all that's needed for
/// balance-bucket classification.
public struct POINodeClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let nodeURLs: [URL]
    private let transport: Transport
    /// Timeout per single request attempt.
    private let requestTimeout: TimeInterval

    public init(
        nodeURLs: [URL],
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 60
    ) {
        self.nodeURLs = nodeURLs
        self.requestTimeout = requestTimeout
        self.transport = { try await session.data(for: $0) }
    }

    /// Test / custom-transport initializer.
    public init(
        nodeURLs: [URL],
        transport: @escaping Transport,
        requestTimeout: TimeInterval = 60
    ) {
        self.nodeURLs = nodeURLs
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    /// Query POI status for one or more blinded commitments.
    ///
    /// Returns a map keyed by blinded commitment; each value is a per-list-key
    /// POIStatus. A blinded commitment missing from the response map means the
    /// POI node has no record of it (treat as `.missing` for all active lists).
    public func poisPerList(
        txidVersion: TXIDVersion = .v2PoseidonMerkle,
        chain: POIChain,
        listKeys: [String],
        queries: [BlindedCommitmentQuery]
    ) async throws -> [String: [String: POIStatus]] {
        guard !nodeURLs.isEmpty else { throw POINodeError.noNodeURLs }
        if queries.isEmpty { return [:] }

        let params: [String: Any] = [
            "chainType": String(chain.type),
            "chainID": String(chain.id),
            "txidVersion": txidVersion.rawValue,
            "listKeys": listKeys,
            "blindedCommitmentDatas": queries.map {
                [
                    "blindedCommitment": $0.blindedCommitment,
                    "type": $0.type.rawValue,
                ]
            },
        ]

        let result = try await attemptRPC(method: "ppoi_pois_per_list", params: params)
        guard let dict = result as? [String: Any] else {
            throw POINodeError.malformedResponse("expected object at result")
        }

        var out: [String: [String: POIStatus]] = [:]
        for (commitment, perList) in dict {
            guard let perListDict = perList as? [String: String] else {
                throw POINodeError.malformedResponse("poisPerList[\(commitment)] not an object")
            }
            var statuses: [String: POIStatus] = [:]
            for (listKey, rawStatus) in perListDict {
                guard let status = POIStatus(rawValue: rawStatus) else {
                    throw POINodeError.malformedResponse("unknown POIStatus: \(rawStatus)")
                }
                statuses[listKey] = status
            }
            out[commitment] = statuses
        }
        return out
    }

    // MARK: - JSON-RPC transport

    /// Attempt the RPC against each node URL in order; if all fail, retry the
    /// first one one more time before giving up (mirrors SDK behavior).
    private func attemptRPC(method: String, params: Any) async throws -> Any {
        var errors: [Error] = []
        for (index, url) in nodeURLs.enumerated() {
            do {
                return try await singleRPC(url: url, method: method, params: params)
            } catch {
                errors.append(error)
                // Try the next URL. If this was the last one, fall through and
                // re-attempt the first URL (SDK's "final attempt" behavior).
                if index == nodeURLs.count - 1 {
                    do {
                        return try await singleRPC(url: nodeURLs[0], method: method, params: params)
                    } catch {
                        errors.append(error)
                    }
                }
            }
        }
        throw POINodeError.allNodesFailed(underlying: errors)
    }

    private func singleRPC(url: URL, method: String, params: Any) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": Int(Date().timeIntervalSince1970 * 1000),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await transport(request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw POINodeError.httpError(http.statusCode)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw POINodeError.malformedResponse("top-level not an object")
        }
        if let errObj = obj["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? -1
            let message = (errObj["message"] as? String) ?? "unknown error"
            throw POINodeError.jsonRPCError(code: code, message: message)
        }
        guard let result = obj["result"] else {
            throw POINodeError.malformedResponse("missing 'result' field")
        }
        return result
    }
}

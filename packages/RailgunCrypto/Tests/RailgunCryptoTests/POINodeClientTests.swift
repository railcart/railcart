import Testing
import Foundation
@testable import RailgunCrypto

@Suite("POI Node Client")
struct POINodeClientTests {
    // MARK: - Request encoding

    @Test("request encodes chain, txidVersion, listKeys, and blindedCommitmentDatas")
    func requestEncoding() async throws {
        let capturedBody = CapturedBody()
        let client = POINodeClient(
            nodeURLs: [URL(string: "https://poi.example")!],
            transport: { request in
                await capturedBody.set(request.httpBody ?? Data())
                return (Self.okResultJSON(["0xabc": ["listkey1": "Valid"]]), Self.http200)
            }
        )

        _ = try await client.poisPerList(
            chain: .ethereumMainnet,
            listKeys: ["listkey1"],
            queries: [
                .init(blindedCommitment: "0xabc", type: .shield),
                .init(blindedCommitment: "0xdef", type: .transact),
            ]
        )

        let body = await capturedBody.value
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["method"] as? String == "ppoi_pois_per_list")

        let params = try #require(json["params"] as? [String: Any])
        #expect(params["chainType"] as? String == "0")
        #expect(params["chainID"] as? String == "1")
        #expect(params["txidVersion"] as? String == "V2_PoseidonMerkle")
        #expect((params["listKeys"] as? [String]) == ["listkey1"])

        let datas = try #require(params["blindedCommitmentDatas"] as? [[String: String]])
        #expect(datas.count == 2)
        #expect(datas[0]["blindedCommitment"] == "0xabc")
        #expect(datas[0]["type"] == "Shield")
        #expect(datas[1]["blindedCommitment"] == "0xdef")
        #expect(datas[1]["type"] == "Transact")
    }

    // MARK: - Response parsing

    @Test("parses per-commitment per-list status map")
    func responseParsing() async throws {
        let client = POINodeClient(
            nodeURLs: [URL(string: "https://poi.example")!],
            transport: { _ in
                (Self.okResultJSON([
                    "0xabc": ["listkey1": "Valid"],
                    "0xdef": ["listkey1": "ShieldBlocked"],
                    "0xffe": ["listkey1": "Missing", "listkey2": "ProofSubmitted"],
                ]), Self.http200)
            }
        )

        let result = try await client.poisPerList(
            chain: .ethereumMainnet,
            listKeys: ["listkey1", "listkey2"],
            queries: [
                .init(blindedCommitment: "0xabc", type: .shield),
                .init(blindedCommitment: "0xdef", type: .shield),
                .init(blindedCommitment: "0xffe", type: .transact),
            ]
        )

        #expect(result["0xabc"]?["listkey1"] == .valid)
        #expect(result["0xdef"]?["listkey1"] == .shieldBlocked)
        #expect(result["0xffe"]?["listkey1"] == .missing)
        #expect(result["0xffe"]?["listkey2"] == .proofSubmitted)
    }

    // MARK: - Error surfaces

    @Test("JSON-RPC error surfaces as jsonRPCError")
    func jsonRPCErrorSurface() async throws {
        let client = POINodeClient(
            nodeURLs: [URL(string: "https://poi.example")!],
            transport: { _ in
                let body = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": ["code": -32000, "message": "backend unavailable"],
                ])
                return (body, Self.http200)
            }
        )

        await #expect(throws: POINodeError.self) {
            _ = try await client.poisPerList(
                chain: .ethereumMainnet,
                listKeys: ["listkey1"],
                queries: [.init(blindedCommitment: "0xabc", type: .shield)]
            )
        }
    }

    @Test("falls back to next node URL when first fails")
    func fallbackOnError() async throws {
        let hitCounter = HitCounter()
        let client = POINodeClient(
            nodeURLs: [
                URL(string: "https://poi-one.example")!,
                URL(string: "https://poi-two.example")!,
            ],
            transport: { request in
                await hitCounter.record(request.url?.host ?? "")
                if request.url?.host == "poi-one.example" {
                    throw URLError(.timedOut)
                }
                return (Self.okResultJSON(["0xabc": ["listkey1": "Valid"]]), Self.http200)
            }
        )

        let result = try await client.poisPerList(
            chain: .ethereumMainnet,
            listKeys: ["listkey1"],
            queries: [.init(blindedCommitment: "0xabc", type: .shield)]
        )
        #expect(result["0xabc"]?["listkey1"] == .valid)

        let hits = await hitCounter.hits
        #expect(hits.contains("poi-one.example"))
        #expect(hits.contains("poi-two.example"))
    }

    @Test("empty queries returns empty without hitting network")
    func emptyQueries() async throws {
        let client = POINodeClient(
            nodeURLs: [URL(string: "https://poi.example")!],
            transport: { _ in
                Issue.record("transport should not be called for empty queries")
                return (Data(), Self.http200)
            }
        )
        let result = try await client.poisPerList(
            chain: .ethereumMainnet,
            listKeys: ["listkey1"],
            queries: []
        )
        #expect(result.isEmpty)
    }

    // MARK: - Helpers

    private static let http200 = HTTPURLResponse(
        url: URL(string: "https://poi.example")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!

    private static func okResultJSON(_ result: [String: [String: String]]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": result,
        ])
    }
}

// MARK: - Test actors

private actor CapturedBody {
    private(set) var value: Data = Data()
    func set(_ data: Data) { value = data }
}

private actor HitCounter {
    private(set) var hits: [String] = []
    func record(_ host: String) { hits.append(host) }
}

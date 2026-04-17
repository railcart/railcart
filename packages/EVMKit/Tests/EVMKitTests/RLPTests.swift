import Testing
import Foundation
@testable import EVMKit

@Suite struct RLPTests {
    @Test func encodeSingleByte() {
        let encoded = RLP.encode(.bytes(Data([0x42])))
        #expect(encoded == Data([0x42]))
    }

    @Test func encodeShortBytes() {
        let data = Data([0x01, 0x02, 0x03])
        let encoded = RLP.encode(.bytes(data))
        #expect(encoded == Data([0x83, 0x01, 0x02, 0x03]))
    }

    @Test func encodeEmptyBytes() {
        let encoded = RLP.encode(.bytes(Data()))
        #expect(encoded == Data([0x80]))
    }

    @Test func encodeEmptyList() {
        let encoded = RLP.encode(.list([]))
        #expect(encoded == Data([0xc0]))
    }

    @Test func encodeNestedList() {
        // [ [], [[]], [ [], [[]] ] ]
        let encoded = RLP.encode(.list([
            .list([]),
            .list([.list([])]),
            .list([.list([]), .list([.list([])])]),
        ]))
        #expect(encoded.hexString == "c7c0c1c0c3c0c1c0")
    }

    @Test func encodeString() {
        let data = "dog".data(using: .utf8)!
        let encoded = RLP.encode(.bytes(data))
        #expect(encoded == Data([0x83]) + data)
    }
}

import Testing
import Foundation
@testable import EVMKit

@Suite struct KeccakTests {
    @Test func emptyHash() {
        // Keccak-256 of empty input
        let hash = Keccak.hash256(Data())
        #expect(hash.hexString == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    @Test func helloWorld() {
        let hash = Keccak.hash256("hello world".data(using: .utf8)!)
        #expect(hash.hexString == "47173285a8d7341e5e972fc677286384f802f8ef42a5ec5f03bbfa254cb01fad")
    }
}

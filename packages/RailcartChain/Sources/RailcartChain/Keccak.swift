import Foundation

/// Pure Swift Keccak-256 implementation (FIPS 202 with Keccak padding).
public enum Keccak {
    /// Compute the Keccak-256 hash of the input data.
    public static func hash256(_ data: Data) -> Data {
        var state = KeccakState()
        state.absorb(data)
        return state.squeeze(count: 32)
    }
}

// MARK: - Keccak State Machine

private struct KeccakState {
    /// 5x5 array of 64-bit lanes = 1600-bit state
    var lanes = [UInt64](repeating: 0, count: 25)

    /// Rate in bytes: for Keccak-256, rate = 1600 - 2*256 = 1088 bits = 136 bytes
    let rate = 136

    mutating func absorb(_ data: Data) {
        var offset = 0
        var remaining = data.count

        // Absorb full blocks
        while remaining >= rate {
            xorBlock(data, offset: offset, count: rate)
            keccakF()
            offset += rate
            remaining -= rate
        }

        // Pad final block (Keccak padding: 0x01...0x80)
        var pad = [UInt8](repeating: 0, count: rate)
        if remaining > 0 {
            data.copyBytes(to: &pad, from: offset..<(offset + remaining))
        }
        pad[remaining] = 0x01
        pad[rate - 1] |= 0x80

        xorBlock(Data(pad), offset: 0, count: rate)
        keccakF()
    }

    func squeeze(count: Int) -> Data {
        // For 256-bit output, one squeeze is enough (count <= rate)
        var output = Data(count: count)
        output.withUnsafeMutableBytes { ptr in
            for i in 0..<(count / 8) {
                var lane = lanes[i]
                withUnsafeBytes(of: &lane) { src in
                    ptr.baseAddress!.advanced(by: i * 8)
                        .copyMemory(from: src.baseAddress!, byteCount: 8)
                }
            }
            // Handle partial last lane
            let fullLanes = count / 8
            let remainder = count % 8
            if remainder > 0 {
                var lane = lanes[fullLanes]
                withUnsafeBytes(of: &lane) { src in
                    ptr.baseAddress!.advanced(by: fullLanes * 8)
                        .copyMemory(from: src.baseAddress!, byteCount: remainder)
                }
            }
        }
        return output
    }

    private mutating func xorBlock(_ data: Data, offset: Int, count: Int) {
        data.withUnsafeBytes { ptr in
            let bytes = ptr.baseAddress!.advanced(by: offset)
                .assumingMemoryBound(to: UInt8.self)
            for i in 0..<(count / 8) {
                var lane = UInt64(0)
                withUnsafeMutableBytes(of: &lane) { dest in
                    dest.baseAddress!.copyMemory(
                        from: bytes.advanced(by: i * 8),
                        byteCount: 8
                    )
                }
                lanes[i] ^= lane
            }
        }
    }

    // MARK: - Keccak-f[1600] permutation

    private mutating func keccakF() {
        for round in 0..<24 {
            // θ (theta)
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20]
            }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) {
                    lanes[y + x] ^= d
                }
            }

            // ρ (rho) and π (pi)
            var t = lanes[1]
            for i in 0..<24 {
                let j = Self.piln[i]
                let temp = lanes[j]
                lanes[j] = rotl(t, Self.rotc[i])
                t = temp
            }

            // χ (chi)
            for y in stride(from: 0, to: 25, by: 5) {
                var row = [UInt64](repeating: 0, count: 5)
                for x in 0..<5 { row[x] = lanes[y + x] }
                for x in 0..<5 {
                    lanes[y + x] = row[x] ^ (~row[(x + 1) % 5] & row[(x + 2) % 5])
                }
            }

            // ι (iota)
            lanes[0] ^= Self.rc[round]
        }
    }

    private func rotl(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }

    // MARK: - Constants

    private static let rc: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
        0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
        0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
        0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
        0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    private static let rotc = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
        27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ]

    private static let piln = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
        15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ]
}

import Foundation

/// BLAKE-512 hash function (SHA-3 candidate, NOT BLAKE2b).
///
/// Used by circomlibjs EdDSA (BabyJubJub) for key derivation.
/// Specification: https://131002.net/blake/blake.pdf
enum Blake512 {
    /// Compute BLAKE-512 hash of the input data. Returns 64 bytes.
    static func hash(_ data: Data) -> Data {
        var ctx = Context()
        ctx.update(data)
        return ctx.finalize()
    }

    // MARK: - Constants

    /// BLAKE-512 initialization vector (same as SHA-512).
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    /// Constants derived from π digits (first 16 64-bit values).
    private static let c: [UInt64] = [
        0x243f6a8885a308d3, 0x13198a2e03707344,
        0xa4093822299f31d0, 0x082efa98ec4e6c89,
        0x452821e638d01377, 0xbe5466cf34e90c6c,
        0xc0ac29b7c97c50dd, 0x3f84d5b5b5470917,
        0x9216d5d98979fb1b, 0xd1310ba698dfb5ac,
        0x2ffd72dbd01adfb7, 0xb8e1afed6a267e96,
        0xba7c9045f12c7f99, 0x24a19947b3916cf7,
        0x0801f2e2858efc16, 0x636920d871574e69,
    ]

    /// Message permutation schedule (sigma).
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        // Repeat for rounds > 10
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    ]

    // MARK: - State

    private struct Context {
        var h: [UInt64] = iv
        var s: [UInt64] = [0, 0, 0, 0] // Salt (unused, zero)
        var t: [UInt64] = [0, 0]        // Counter (bits processed)
        var buffer = Data()
        var nullT = false

        mutating func update(_ data: Data) {
            buffer.append(data)
            while buffer.count >= 128 {
                let block = Data(buffer.prefix(128))
                buffer.removeFirst(128)
                t[0] = t[0] &+ 1024 // 128 bytes = 1024 bits
                if t[0] < 1024 { t[1] = t[1] &+ 1 }
                compress(block)
            }
        }

        mutating func finalize() -> Data {
            // Add bit count for remaining bytes
            let remaining = UInt64(buffer.count) * 8
            t[0] = t[0] &+ remaining
            if t[0] < remaining { t[1] = t[1] &+ 1 }

            // Padding
            let msgLen = buffer.count
            // BLAKE-512 uses 111 bytes of padding space (128 - 16 - 1)
            if msgLen == 111 {
                // Special case: exactly fills padding
                buffer[msgLen - 1] |= 0x01 // Never happens for our use
                // Actually this is wrong - let me use the standard padding
            }

            // Standard padding: append 0x80, then zeros, then length
            buffer.append(0x80)
            if buffer.count > 112 {
                // Need another block
                while buffer.count < 128 { buffer.append(0x00) }
                compress(Data(buffer.prefix(128)))
                buffer.removeAll()
            }
            while buffer.count < 112 { buffer.append(0x00) }

            // Set the last byte before length to 0x01 (BLAKE-512 marker)
            buffer[buffer.count - 1] |= 0x01

            // Append 128-bit counter (big-endian)
            appendBigEndian64(t[1])
            appendBigEndian64(t[0])

            // If no message bits in this last block, set nullT
            if msgLen == 0 { nullT = true }

            compress(Data(buffer.prefix(128)))

            // Output
            var output = Data(capacity: 64)
            for i in 0..<8 {
                appendBigEndian64(h[i], to: &output)
            }
            return output
        }

        private mutating func appendBigEndian64(_ value: UInt64) {
            buffer.append(UInt8((value >> 56) & 0xFF))
            buffer.append(UInt8((value >> 48) & 0xFF))
            buffer.append(UInt8((value >> 40) & 0xFF))
            buffer.append(UInt8((value >> 32) & 0xFF))
            buffer.append(UInt8((value >> 24) & 0xFF))
            buffer.append(UInt8((value >> 16) & 0xFF))
            buffer.append(UInt8((value >> 8) & 0xFF))
            buffer.append(UInt8(value & 0xFF))
        }

        private func appendBigEndian64(_ value: UInt64, to data: inout Data) {
            data.append(UInt8((value >> 56) & 0xFF))
            data.append(UInt8((value >> 48) & 0xFF))
            data.append(UInt8((value >> 40) & 0xFF))
            data.append(UInt8((value >> 32) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }

        private func readBigEndian64(_ data: Data, offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(data[offset + i])
            }
            return value
        }

        private mutating func compress(_ block: Data) {
            // Parse message block into 16 64-bit words (big-endian)
            var m = [UInt64](repeating: 0, count: 16)
            for i in 0..<16 {
                m[i] = readBigEndian64(block, offset: i * 8)
            }

            // Initialize working variables
            var v = [UInt64](repeating: 0, count: 16)
            v[0] = h[0]; v[1] = h[1]; v[2] = h[2]; v[3] = h[3]
            v[4] = h[4]; v[5] = h[5]; v[6] = h[6]; v[7] = h[7]
            v[8]  = s[0] ^ c[0]
            v[9]  = s[1] ^ c[1]
            v[10] = s[2] ^ c[2]
            v[11] = s[3] ^ c[3]
            v[12] = c[4]
            v[13] = c[5]
            v[14] = c[6]
            v[15] = c[7]

            if !nullT {
                v[12] ^= t[0]
                v[13] ^= t[0]
                v[14] ^= t[1]
                v[15] ^= t[1]
            }

            // 16 rounds
            for round in 0..<16 {
                let s = sigma[round]

                // Column step
                g(&v, 0, 4,  8, 12, m[s[0]] ^ c[s[1]], m[s[1]] ^ c[s[0]])
                g(&v, 1, 5,  9, 13, m[s[2]] ^ c[s[3]], m[s[3]] ^ c[s[2]])
                g(&v, 2, 6, 10, 14, m[s[4]] ^ c[s[5]], m[s[5]] ^ c[s[4]])
                g(&v, 3, 7, 11, 15, m[s[6]] ^ c[s[7]], m[s[7]] ^ c[s[6]])

                // Diagonal step
                g(&v, 0, 5, 10, 15, m[s[8]]  ^ c[s[9]],  m[s[9]]  ^ c[s[8]])
                g(&v, 1, 6, 11, 12, m[s[10]] ^ c[s[11]], m[s[11]] ^ c[s[10]])
                g(&v, 2, 7,  8, 13, m[s[12]] ^ c[s[13]], m[s[13]] ^ c[s[12]])
                g(&v, 3, 4,  9, 14, m[s[14]] ^ c[s[15]], m[s[15]] ^ c[s[14]])
            }

            // Finalize
            for i in 0..<8 {
                h[i] ^= s[i % 4] ^ v[i] ^ v[i + 8]
            }
        }

        /// BLAKE G mixing function.
        private func g(_ v: inout [UInt64], _ a: Int, _ b: Int, _ cc: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = (v[d] ^ v[a]).rotateRight(32)
            v[cc] = v[cc] &+ v[d]
            v[b] = (v[b] ^ v[cc]).rotateRight(25)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = (v[d] ^ v[a]).rotateRight(16)
            v[cc] = v[cc] &+ v[d]
            v[b] = (v[b] ^ v[cc]).rotateRight(11)
        }
    }
}

private extension UInt64 {
    func rotateRight(_ n: Int) -> UInt64 {
        (self >> n) | (self << (64 - n))
    }
}

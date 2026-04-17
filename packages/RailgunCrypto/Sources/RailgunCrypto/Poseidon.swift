import BigInt
import RsPoseidon

/// Poseidon hash function over the BN254 scalar field.
///
/// Backed by rs-poseidon (https://github.com/logos-storage/rs-poseidon),
/// the same implementation used by RAILGUN's poseidon-hash-wasm.
public enum Poseidon {
    /// Compute the Poseidon hash of 1–4 field elements.
    ///
    /// Returns a single field element (the capacity cell after permutation).
    public static func hash(_ inputs: [BigUInt]) -> BigUInt {
        precondition(!inputs.isEmpty && inputs.count <= 4,
                     "Poseidon supports 1–4 inputs, got \(inputs.count)")

        // Reduce inputs mod p (rs-poseidon requires values < field prime)
        let reduced = inputs.map { $0 % BN254Field.prime }

        // Pack into a flat contiguous buffer: [input0_limb0..3, input1_limb0..3, ...]
        var flat = [UInt64](repeating: 0, count: reduced.count * 4)
        for (i, val) in reduced.enumerated() {
            let words = val.words
            for j in 0..<min(words.count, 4) {
                flat[i * 4 + j] = UInt64(words[j])
            }
        }

        var output: [UInt64] = [0, 0, 0, 0]

        flat.withUnsafeBufferPointer { flatBuf in
            flatBuf.baseAddress!.withMemoryRebound(
                to: (UInt64, UInt64, UInt64, UInt64).self,
                capacity: inputs.count
            ) { ptr in
                output.withUnsafeMutableBufferPointer { outBuf in
                    poseidon_hash(ptr, Int32(inputs.count), outBuf.baseAddress!)
                }
            }
        }

        return limbsToBigUInt(output)
    }

    /// Convenience: hash two field elements (used for merkle tree nodes).
    public static func hash(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        hash([a, b])
    }

    /// Hash inputs and return the result as a 0x-prefixed hex string (64 chars, zero-padded).
    public static func hashHex(_ inputs: [BigUInt]) -> String {
        let result = hash(inputs)
        return "0x" + String(result, radix: 16).paddedLeft(toLength: 64, with: "0")
    }

    // MARK: - Limb conversion

    /// Convert 4 little-endian uint64 limbs to a BigUInt.
    private static func limbsToBigUInt(_ limbs: [UInt64]) -> BigUInt {
        var result = BigUInt(limbs[3])
        result <<= 64
        result |= BigUInt(limbs[2])
        result <<= 64
        result |= BigUInt(limbs[1])
        result <<= 64
        result |= BigUInt(limbs[0])
        return result
    }
}

extension String {
    func paddedLeft(toLength length: Int, with pad: Character) -> String {
        if count >= length { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

import BigInt

/// Poseidon hash function over the BN254 scalar field.
///
/// Implements the Hades permutation design with parameters matching
/// the RAILGUN/circomlibjs implementation:
/// - S-box: x^5
/// - Full rounds: 8 (4 at start, 4 at end)
/// - Partial rounds: varies by state width (56, 57, 56, 60)
/// - Field: BN254 scalar field (Fr)
///
/// Supports 1–4 inputs (state width t = 2–5).
public enum Poseidon {
    /// Number of full rounds (split half before, half after partial rounds).
    private static let nRoundsF = 8

    /// Compute the Poseidon hash of 1–4 field elements.
    ///
    /// Returns a single field element (the capacity cell after permutation).
    public static func hash(_ inputs: [BigUInt]) -> BigUInt {
        precondition(!inputs.isEmpty && inputs.count <= 4,
                     "Poseidon supports 1–4 inputs, got \(inputs.count)")

        let t = inputs.count + 1
        let idx = t - 2 // index into constants arrays
        let nRoundsP = PoseidonConstants.nRoundsP[idx]
        let totalRounds = nRoundsF + nRoundsP
        let C = PoseidonConstants.C[idx]
        let M = PoseidonConstants.M[idx]
        let F = BN254Field.self

        // Initial state: [0, input1, input2, ...]
        var state = [F.zero] + inputs.map { F.reduce($0) }

        for r in 0..<totalRounds {
            // AddRoundConstants
            for i in 0..<t {
                state[i] = F.add(state[i], C[r * t + i])
            }

            // SubWords (S-box)
            if r < nRoundsF / 2 || r >= nRoundsF / 2 + nRoundsP {
                // Full round: apply S-box to all elements
                for i in 0..<t {
                    state[i] = F.pow5(state[i])
                }
            } else {
                // Partial round: apply S-box only to first element
                state[0] = F.pow5(state[0])
            }

            // MixLayer (MDS matrix multiplication)
            var newState = [BigUInt](repeating: F.zero, count: t)
            for i in 0..<t {
                var acc = F.zero
                for j in 0..<t {
                    acc = F.add(acc, F.mul(M[i][j], state[j]))
                }
                newState[i] = acc
            }
            state = newState
        }

        return state[0]
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
}

extension String {
    func paddedLeft(toLength length: Int, with pad: Character) -> String {
        if count >= length { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

import BigInt

/// Arithmetic in the BN254 scalar field (Fr).
/// All operations are modulo the SNARK prime.
public enum BN254Field {
    /// The BN254 scalar field order (SNARK_PRIME).
    public static let prime = BigUInt("21888242871839275222246405745257275088548364400416034343698204186575808495617")

    /// The zero element.
    public static let zero = BigUInt(0)

    /// The one element.
    public static let one = BigUInt(1)

    /// Reduce a value modulo the prime.
    @inline(__always)
    public static func reduce(_ a: BigUInt) -> BigUInt {
        a % prime
    }

    /// Addition in the field.
    @inline(__always)
    public static func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        (a + b) % prime
    }

    /// Multiplication in the field.
    @inline(__always)
    public static func mul(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        (a * b) % prime
    }

    /// Squaring in the field (slightly more efficient than mul(a, a) in some implementations).
    @inline(__always)
    public static func square(_ a: BigUInt) -> BigUInt {
        (a * a) % prime
    }

    /// Compute a^5 mod p (the S-box for Poseidon).
    @inline(__always)
    public static func pow5(_ a: BigUInt) -> BigUInt {
        let a2 = square(a)
        let a4 = square(a2)
        return mul(a4, a)
    }
}

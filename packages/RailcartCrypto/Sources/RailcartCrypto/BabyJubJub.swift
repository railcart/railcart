import BigInt

/// BabyJubJub twisted Edwards curve over the BN254 base field.
///
/// Curve equation: A*x^2 + y^2 = 1 + D*x^2*y^2
/// Field: BN254 scalar field (same as Poseidon)
public enum BabyJubJub {
    public typealias Point = (x: BigUInt, y: BigUInt)

    private static let F = BN254Field.self
    private static let p = BN254Field.prime

    /// Curve parameter A.
    static let A = BigUInt(168700)
    /// Curve parameter D.
    static let D = BigUInt(168696)

    /// Generator point.
    public static let generator: Point = (
        x: BigUInt("995203441582195749578291179787384436505546430278305826713579947235728471134"),
        y: BigUInt("5472060717959818805561601436314318772137091100104008585924551046643952123905")
    )

    /// Base8 point (generator divided by 8, used for EdDSA).
    public static let base8: Point = (
        x: BigUInt("5299619240641551281634865583518297030282874472190772894086521144482721001553"),
        y: BigUInt("16950150798460657717958625567821834550301663161624707787222815936182638968203")
    )

    /// The identity point (neutral element for addition).
    public static let identity: Point = (x: BigUInt(0), y: BigUInt(1))

    /// Add two points on the curve.
    public static func addPoints(_ a: Point, _ b: Point) -> Point {
        let beta = F.mul(a.x, b.y)
        let gamma = F.mul(a.y, b.x)
        let delta = F.mul(
            F.add(p - F.mul(A, a.x) + a.y, p), // (a.y - A*a.x) mod p
            F.add(b.x, b.y)
        )

        let tau = F.mul(beta, gamma)
        let dtau = F.mul(D, tau)

        let x = F.mul(
            F.add(beta, gamma),
            modInverse(F.add(1, dtau), p)
        )

        let subABetaGamma = F.add(p + F.mul(A, beta) - gamma, p) // (A*beta - gamma) mod p
        let y = F.mul(
            F.add(delta, subABetaGamma),
            modInverse(F.add(p - dtau + 1, p), p) // (1 - dtau) mod p
        )

        return (x: x, y: y)
    }

    /// Scalar multiplication: point * scalar.
    public static func mulPointScalar(_ base: Point, _ scalar: BigUInt) -> Point {
        var result = identity
        var exp = base
        var rem = scalar

        while rem > 0 {
            if rem & 1 == 1 {
                result = addPoints(result, exp)
            }
            exp = addPoints(exp, exp)
            rem >>= 1
        }

        return result
    }

    /// Check if a point is on the curve.
    public static func isOnCurve(_ point: Point) -> Bool {
        let x2 = F.square(point.x)
        let y2 = F.square(point.y)
        let lhs = F.add(F.mul(A, x2), y2) // A*x^2 + y^2
        let rhs = F.add(1, F.mul(D, F.mul(x2, y2))) // 1 + D*x^2*y^2
        return lhs == rhs
    }
}

/// Compute modular inverse using extended Euclidean algorithm.
/// Returns a^(-1) mod m.
func modInverse(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
    // Use Fermat's little theorem: a^(-1) = a^(m-2) mod m (for prime m)
    a.power(m - 2, modulus: m)
}

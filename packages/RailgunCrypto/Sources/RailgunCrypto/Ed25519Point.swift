import BigInt
import Foundation
import CryptoKit
import CSodium

/// RAILGUN ECDH shared symmetric key derivation.
///
/// Matches the SDK's `getSharedSymmetricKey(privateKey, blindedPublicKey)`:
/// 1. SHA-512(privateKey) → take first 32 bytes → clamp for X25519
/// 2. Interpret as scalar mod curve order l
/// 3. Scalar multiply blindedPublicKey (Ed25519 point) by scalar
/// 4. SHA-256(result) → 32-byte symmetric key
///
/// Uses libsodium's `crypto_scalarmult_ed25519_noclamp` for fast Ed25519 point multiplication.
public enum RailgunECDH {
    /// Ed25519 group order.
    private static let l = BigUInt("7237005577332262213973186563042994240857116359379907606001950938285454250989")

    /// One-time libsodium init.
    private static let sodiumReady: Bool = {
        sodium_init() >= 0
    }()

    /// Precomputed private scalar from a viewing key.
    /// Avoids recomputing SHA-512 + BigUInt mod reduction for every commitment.
    public struct PreparedKey: Sendable {
        /// The scalar in little-endian 32-byte format, ready for libsodium.
        let scalarLE: Data  // 32 bytes
    }

    /// Precompute the private scalar from a viewing key.
    /// Call this once per wallet, then use `sharedKeyFast` for each commitment.
    public static func prepareKey(viewingPrivateKey: Data) -> PreparedKey? {
        guard viewingPrivateKey.count == 32 else { return nil }

        let hash = Data(SHA512.hash(data: viewingPrivateKey))
        var head = Data(hash.prefix(32))
        head[0] &= 0xF8
        head[31] &= 0x7F
        head[31] |= 0x40

        let scalarBigEndian = BigUInt(Data(head.reversed()))
        let reduced = scalarBigEndian % l
        guard reduced > 0 else { return nil }

        return PreparedKey(scalarLE: reducedToLE32(reduced))
    }

    /// Fast shared key derivation using a precomputed scalar.
    /// Only does: libsodium scalar multiply + SHA-256.
    public static func sharedKeyFast(
        preparedKey: PreparedKey,
        blindedPublicKey: Data
    ) -> Data? {
        guard blindedPublicKey.count == 32 else { return nil }
        precondition(sodiumReady, "libsodium init failed")

        var scalarLE = preparedKey.scalarLE
        var result = Data(count: 32)
        let rc = result.withUnsafeMutableBytes { resultPtr in
            scalarLE.withUnsafeMutableBytes { scalarPtr in
                blindedPublicKey.withUnsafeBytes { pointPtr in
                    crypto_scalarmult_ed25519_noclamp(
                        resultPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        scalarPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        pointPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    )
                }
            }
        }

        guard rc == 0 else { return nil }
        return Data(SHA256.hash(data: result))
    }

    /// Derive the shared symmetric key for decrypting a note (convenience, not for hot paths).
    public static func sharedKey(
        viewingPrivateKey: Data,
        blindedPublicKey: Data
    ) -> Data? {
        guard let prepared = prepareKey(viewingPrivateKey: viewingPrivateKey) else {
            return nil
        }
        return sharedKeyFast(preparedKey: prepared, blindedPublicKey: blindedPublicKey)
    }

    /// Convert a BigUInt scalar to 32 bytes little-endian.
    private static func reducedToLE32(_ value: BigUInt) -> Data {
        var bytes = value.serialize() // big-endian
        while bytes.count < 32 { bytes.insert(0, at: 0) }
        if bytes.count > 32 { bytes = Data(bytes.suffix(32)) }
        return Data(bytes.reversed()) // to little-endian
    }
}

// MARK: - Ed25519 point operations (kept for tests/verification, not used in hot path)

/// Ed25519 point arithmetic using BigUInt (slow, for verification only).
/// Production code uses libsodium via RailgunECDH.
public enum Ed25519Curve {
    public static let p = BigUInt(1) << 255 - BigUInt(19)

    public static let d: BigUInt = {
        let neg121665 = p - BigUInt(121665)
        let inv121666 = BigUInt(121666).power(p - 2, modulus: p)
        return (neg121665 * inv121666) % p
    }()

    public struct Point: Sendable {
        public let x: BigUInt
        public let y: BigUInt

        public static let identity = Point(x: 0, y: 1)

        public init(compressed: Data) {
            precondition(compressed.count == 32)
            let xSign = (compressed[31] & 0x80) != 0
            var yBytes = Data(compressed)
            yBytes[31] &= 0x7F
            let y = BigUInt(Data(yBytes.reversed()))

            let y2 = (y * y) % Ed25519Curve.p
            let num = (y2 + Ed25519Curve.p - 1) % Ed25519Curve.p
            let den = (Ed25519Curve.d * y2 + 1) % Ed25519Curve.p
            let denInv = den.power(Ed25519Curve.p - 2, modulus: Ed25519Curve.p)
            let x2 = (num * denInv) % Ed25519Curve.p

            var x = x2.power((Ed25519Curve.p + 3) / 8, modulus: Ed25519Curve.p)
            if (x * x) % Ed25519Curve.p != x2 {
                let sqrtM1 = BigUInt(2).power((Ed25519Curve.p - 1) / 4, modulus: Ed25519Curve.p)
                x = (x * sqrtM1) % Ed25519Curve.p
            }
            if (x & 1 == 1) != xSign { x = Ed25519Curve.p - x }

            self.x = x
            self.y = y
        }

        public init(x: BigUInt, y: BigUInt) {
            self.x = x
            self.y = y
        }

        public func compress() -> Data {
            var yBytes = y.serialize()
            while yBytes.count < 32 { yBytes.insert(0, at: 0) }
            var result = Data(yBytes.reversed())
            if x & 1 == 1 { result[31] |= 0x80 }
            return result
        }
    }

    public static func add(_ a: Point, _ b: Point) -> Point {
        let x1y2 = (a.x * b.y) % p
        let x2y1 = (b.x * a.y) % p
        let y1y2 = (a.y * b.y) % p
        let x1x2 = (a.x * b.x) % p
        let dx1x2y1y2 = (d * x1x2 % p * y1y2) % p

        let xNum = (x1y2 + x2y1) % p
        let xDen = (1 + dx1x2y1y2) % p
        let x3 = (xNum * xDen.power(p - 2, modulus: p)) % p

        let yNum = (y1y2 + x1x2) % p
        let yDen = (p + 1 - dx1x2y1y2) % p
        let y3 = (yNum * yDen.power(p - 2, modulus: p)) % p

        return Point(x: x3, y: y3)
    }

    public static func scalarMul(_ point: Point, _ scalar: BigUInt) -> Point {
        var result = Point.identity
        var exp = point
        var rem = scalar
        while rem > 0 {
            if rem & 1 == 1 { result = add(result, exp) }
            exp = add(exp, exp)
            rem >>= 1
        }
        return result
    }
}

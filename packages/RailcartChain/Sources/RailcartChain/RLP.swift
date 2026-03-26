import Foundation

/// Recursive Length Prefix encoding for Ethereum.
public enum RLP {
    /// An RLP-encodable item: either raw bytes or a list of items.
    public enum Item {
        case bytes(Data)
        case list([Item])
    }

    /// Encode an RLP item to bytes.
    public static func encode(_ item: Item) -> Data {
        switch item {
        case .bytes(let data):
            return encodeBytes(data)
        case .list(let items):
            let payload = items.reduce(Data()) { $0 + encode($1) }
            return encodeLength(payload.count, offset: 0xc0) + payload
        }
    }

    // MARK: - Private

    private static func encodeBytes(_ data: Data) -> Data {
        if data.count == 1 && data[0] < 0x80 {
            return data
        }
        return encodeLength(data.count, offset: 0x80) + data
    }

    private static func encodeLength(_ length: Int, offset: UInt8) -> Data {
        if length < 56 {
            return Data([offset + UInt8(length)])
        }
        let lengthBytes = bigEndianBytes(length)
        return Data([offset + 55 + UInt8(lengthBytes.count)]) + lengthBytes
    }

    private static func bigEndianBytes(_ value: Int) -> Data {
        var v = value
        var bytes: [UInt8] = []
        while v > 0 {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return Data(bytes)
    }
}

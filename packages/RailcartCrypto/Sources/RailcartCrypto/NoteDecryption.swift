import BigInt
import Foundation
import CryptoKit

/// Decrypted RAILGUN note data.
public struct DecryptedNote: Sendable {
    public let masterPublicKey: BigUInt
    public let tokenHash: BigUInt
    public let random: Data          // 16 bytes
    public let value: BigUInt
    public let memoText: String?
    public let isSentNote: Bool
}

/// V2 ciphertext structure as decoded from commitment events.
public struct CommitmentCiphertextV2: Sendable {
    public let iv: Data              // 16 bytes
    public let tag: Data             // 16 bytes
    public let data: [Data]          // Array of 32-byte blocks
    public let blindedSenderViewingKey: Data    // 32 bytes
    public let blindedReceiverViewingKey: Data  // 32 bytes
    public let memo: Data?

    public init(iv: Data, tag: Data, data: [Data],
                blindedSenderViewingKey: Data, blindedReceiverViewingKey: Data,
                memo: Data? = nil) {
        self.iv = iv
        self.tag = tag
        self.data = data
        self.blindedSenderViewingKey = blindedSenderViewingKey
        self.blindedReceiverViewingKey = blindedReceiverViewingKey
        self.memo = memo
    }
}

/// Attempt to decrypt a V2 commitment and extract note data.
public enum NoteDecryptor {
    /// Try to decrypt a V2 transact commitment using a precomputed key (fast path).
    ///
    /// Returns a `DecryptedNote` if the commitment belongs to this wallet, nil otherwise.
    /// Tries both receiver and sender shared keys.
    public static func decryptV2(
        ciphertext: CommitmentCiphertextV2,
        preparedKey: RailgunECDH.PreparedKey
    ) -> DecryptedNote? {
        // Try as receiver (use blindedSenderViewingKey to derive shared key)
        if let receiverKey = RailgunECDH.sharedKeyFast(
            preparedKey: preparedKey,
            blindedPublicKey: ciphertext.blindedSenderViewingKey
        ) {
            if let note = tryDecryptV2(
                ciphertext: ciphertext,
                sharedKey: receiverKey,
                memo: ciphertext.memo,
                isSentNote: false
            ) {
                return note
            }
        }

        // Try as sender (use blindedReceiverViewingKey to derive shared key)
        if let senderKey = RailgunECDH.sharedKeyFast(
            preparedKey: preparedKey,
            blindedPublicKey: ciphertext.blindedReceiverViewingKey
        ) {
            if let note = tryDecryptV2(
                ciphertext: ciphertext,
                sharedKey: senderKey,
                memo: ciphertext.memo,
                isSentNote: true
            ) {
                return note
            }
        }

        return nil
    }

    /// Convenience: decrypt with raw viewing private key (precomputes scalar each time).
    public static func decryptV2(
        ciphertext: CommitmentCiphertextV2,
        viewingPrivateKey: Data
    ) -> DecryptedNote? {
        guard let prepared = RailgunECDH.prepareKey(viewingPrivateKey: viewingPrivateKey) else {
            return nil
        }
        return decryptV2(ciphertext: ciphertext, preparedKey: prepared)
    }

    /// Decrypt the ciphertext data blocks with AES-256-GCM.
    static func aesGCMDecrypt(key: Data, iv: Data, tag: Data, data: [Data]) -> [Data]? {
        guard key.count == 32, iv.count == 16, tag.count == 16 else { return nil }

        // Combine all data blocks into a single ciphertext
        var combined = Data()
        for block in data {
            combined.append(block)
        }

        // AES-256-GCM decryption
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: combined,
                tag: tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))

            // Split back into 32-byte blocks
            var blocks = [Data]()
            var offset = 0
            for block in data {
                let end = offset + block.count
                if end <= decrypted.count {
                    blocks.append(Data(decrypted[offset..<end]))
                }
                offset = end
            }
            return blocks
        } catch {
            return nil
        }
    }

    /// Try to decrypt and parse a V2 note with a given shared key.
    private static func tryDecryptV2(
        ciphertext: CommitmentCiphertextV2,
        sharedKey: Data,
        memo: Data?,
        isSentNote: Bool
    ) -> DecryptedNote? {
        guard let decrypted = aesGCMDecrypt(
            key: sharedKey,
            iv: ciphertext.iv,
            tag: ciphertext.tag,
            data: ciphertext.data
        ) else {
            return nil
        }

        guard decrypted.count >= 3 else { return nil }

        // decrypted[0]: Master Public Key (32 bytes)
        let masterPublicKey = BigUInt(decrypted[0])

        // decrypted[1]: Token Hash (32 bytes)
        let tokenHash = BigUInt(decrypted[1])

        // decrypted[2]: Random (first 16 bytes) + Value (last 16 bytes)
        guard decrypted[2].count == 32 else { return nil }
        let random = Data(decrypted[2].prefix(16))
        let value = BigUInt(Data(decrypted[2].suffix(16)))

        // decrypted[3+]: Memo text (optional, UTF-8 encoded)
        var memoText: String?
        if decrypted.count > 3 {
            var memoData = Data()
            for i in 3..<decrypted.count {
                memoData.append(decrypted[i])
            }
            // Trim trailing zeros
            while let last = memoData.last, last == 0 { memoData.removeLast() }
            if !memoData.isEmpty {
                memoText = String(data: memoData, encoding: .utf8)
            }
        }

        return DecryptedNote(
            masterPublicKey: masterPublicKey,
            tokenHash: tokenHash,
            random: random,
            value: value,
            memoText: memoText,
            isSentNote: isSentNote
        )
    }
}

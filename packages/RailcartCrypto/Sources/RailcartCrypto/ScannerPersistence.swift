import BigInt
import Foundation

/// Serializable scanner state for persisting between app launches.
struct ScannerState: Codable {
    let lastScannedBlock: Int
    let utxos: [SerializedUTXO]
    let nullifiers: [String]  // hex strings
    let pendingLeaves: [Int: [SerializedLeaf]]  // tree number → leaves
    /// Optional nullifier → txid (hex) map. Older state files don't have it
    /// and the debug view will miss dependencies until next rescan.
    let nullifierTxids: [String: String]?

    struct SerializedUTXO: Codable {
        let tree: Int
        let position: Int
        let hash: String       // hex
        let txid: String       // hex
        let blockNumber: Int
        let tokenHash: String  // hex (BigUInt)
        let value: String      // decimal (BigUInt)
        let random: String     // hex
        let masterPublicKey: String  // hex (BigUInt)
        let isSentNote: Bool
        let nullifier: String? // hex (BigUInt)
        let isSpent: Bool
        let commitmentType: String
        /// Optional for backward compat with pre-POI saved state.
        let blindedCommitment: String?
        /// Optional for backward compat. Raw `WalletBalanceBucket` value.
        let balanceBucket: String?
    }

    struct SerializedLeaf: Codable {
        let position: Int
        let hash: String  // hex
    }
}

extension Scanner {
    /// Save scanner state to a file.
    public func save(to url: URL) throws {
        let state = ScannerState(
            lastScannedBlock: lastScannedBlock,
            utxos: utxos.map { utxo in
                ScannerState.SerializedUTXO(
                    tree: utxo.tree,
                    position: utxo.position,
                    hash: utxo.hash.map { String(format: "%02x", $0) }.joined(),
                    txid: utxo.txid.map { String(format: "%02x", $0) }.joined(),
                    blockNumber: utxo.blockNumber,
                    tokenHash: String(utxo.tokenHash, radix: 16),
                    value: String(utxo.value),
                    random: utxo.random.map { String(format: "%02x", $0) }.joined(),
                    masterPublicKey: String(utxo.masterPublicKey, radix: 16),
                    isSentNote: utxo.isSentNote,
                    nullifier: utxo.nullifier.map { String($0, radix: 16) },
                    isSpent: utxo.isSpent,
                    commitmentType: utxo.commitmentType.rawValue,
                    blindedCommitment: utxo.blindedCommitment,
                    balanceBucket: utxo.balanceBucket.rawValue
                )
            },
            nullifiers: knownNullifiersList.map { String($0, radix: 16) },
            pendingLeaves: pendingLeavesList.mapValues { leaves in
                leaves.map { ScannerState.SerializedLeaf(
                    position: $0.position,
                    hash: $0.hash.map { String(format: "%02x", $0) }.joined()
                )}
            },
            nullifierTxids: Dictionary(uniqueKeysWithValues: nullifierTxidsList.map { nullifier, txid in
                (String(nullifier, radix: 16),
                 txid.map { String(format: "%02x", $0) }.joined())
            })
        )

        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Load scanner state from a file.
    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(ScannerState.self, from: data)

        restoreState(
            lastScannedBlock: state.lastScannedBlock,
            utxos: state.utxos.compactMap { s in
                guard let hash = Data(hexString: s.hash),
                      let txid = Data(hexString: s.txid),
                      let tokenHash = BigUInt(s.tokenHash, radix: 16),
                      let random = Data(hexString: s.random),
                      let masterPK = BigUInt(s.masterPublicKey, radix: 16),
                      let commitmentType = CommitmentType(rawValue: s.commitmentType)
                else { return nil }

                var utxo = UTXO(
                    tree: s.tree,
                    position: s.position,
                    hash: hash,
                    txid: txid,
                    blockNumber: s.blockNumber,
                    tokenHash: tokenHash,
                    value: BigUInt(s.value) ?? 0,
                    random: random,
                    masterPublicKey: masterPK,
                    isSentNote: s.isSentNote,
                    nullifier: s.nullifier.flatMap { BigUInt($0, radix: 16) },
                    commitmentType: commitmentType
                )
                utxo.isSpent = s.isSpent
                utxo.blindedCommitment = s.blindedCommitment
                if let raw = s.balanceBucket, let bucket = WalletBalanceBucket(rawValue: raw) {
                    utxo.balanceBucket = bucket
                }
                return utxo
            },
            nullifiers: Set(state.nullifiers.compactMap { BigUInt($0, radix: 16) }),
            pendingLeaves: state.pendingLeaves.mapValues { leaves in
                leaves.compactMap { s in
                    guard let hash = Data(hexString: s.hash) else { return nil }
                    return (position: s.position, hash: hash)
                }
            },
            nullifierTxids: {
                guard let raw = state.nullifierTxids else { return [:] }
                var map: [BigUInt: Data] = [:]
                for (k, v) in raw {
                    if let key = BigUInt(k, radix: 16),
                       let value = Data(hexString: v) {
                        map[key] = value
                    }
                }
                return map
            }()
        )
    }
}

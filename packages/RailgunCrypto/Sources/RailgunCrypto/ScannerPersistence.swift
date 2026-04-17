import BigInt
import Foundation

/// On-disk metadata. `lastScannedBlock` is the commit anchor — meta.json is
/// written last, so any data files on disk contain at least up to this block.
struct ScannerMeta: Codable {
    let version: Int
    let lastScannedBlock: Int
}

/// Wire format for a single UTXO. Top-level so utxos.json can be encoded
/// independently of the rest of the scanner state.
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
    let blindedCommitment: String?
    let balanceBucket: String?

    init(_ utxo: UTXO) {
        self.tree = utxo.tree
        self.position = utxo.position
        self.hash = utxo.hash.hexString
        self.txid = utxo.txid.hexString
        self.blockNumber = utxo.blockNumber
        self.tokenHash = String(utxo.tokenHash, radix: 16)
        self.value = String(utxo.value)
        self.random = utxo.random.hexString
        self.masterPublicKey = String(utxo.masterPublicKey, radix: 16)
        self.isSentNote = utxo.isSentNote
        self.nullifier = utxo.nullifier.map { String($0, radix: 16) }
        self.isSpent = utxo.isSpent
        self.commitmentType = utxo.commitmentType.rawValue
        self.blindedCommitment = utxo.blindedCommitment
        self.balanceBucket = utxo.balanceBucket.rawValue
    }

    func toUTXO() -> UTXO? {
        guard let hash = Data(hexString: hash),
              let txid = Data(hexString: txid),
              let tokenHash = BigUInt(tokenHash, radix: 16),
              let random = Data(hexString: random),
              let masterPK = BigUInt(masterPublicKey, radix: 16),
              let commitmentType = CommitmentType(rawValue: commitmentType)
        else { return nil }

        var utxo = UTXO(
            tree: tree,
            position: position,
            hash: hash,
            txid: txid,
            blockNumber: blockNumber,
            tokenHash: tokenHash,
            value: BigUInt(value) ?? 0,
            random: random,
            masterPublicKey: masterPK,
            isSentNote: isSentNote,
            nullifier: nullifier.flatMap { BigUInt($0, radix: 16) },
            commitmentType: commitmentType
        )
        utxo.isSpent = isSpent
        utxo.blindedCommitment = blindedCommitment
        if let raw = balanceBucket, let bucket = WalletBalanceBucket(rawValue: raw) {
            utxo.balanceBucket = bucket
        }
        return utxo
    }
}

/// Legacy single-file format. Only used to migrate old saved state on first
/// load — never written.
private struct LegacyScannerState: Codable {
    let lastScannedBlock: Int
    let utxos: [SerializedUTXO]
    let nullifiers: [String]
    let pendingLeaves: [Int: [LegacyLeaf]]
    let nullifierTxids: [String: String]?

    struct LegacyLeaf: Codable {
        let position: Int
        let hash: String
    }
}

extension Scanner {
    /// Current on-disk format version.
    private static var persistenceVersion: Int { 2 }

    /// Save scanner state to a directory. New nullifiers, txid mappings, and
    /// pending leaves are appended to per-type log files; only utxos.json and
    /// meta.json are fully rewritten. meta.json is written last and acts as the
    /// commit marker.
    public func save(to directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        // Append new pending leaves per tree.
        let leavesDir = directoryURL.appendingPathComponent("pending-leaves", isDirectory: true)
        try FileManager.default.createDirectory(at: leavesDir, withIntermediateDirectories: true)
        for (tree, leaves) in pendingLeavesList {
            let saved = savedLeafCountsValue[tree] ?? 0
            guard leaves.count > saved else { continue }
            let lines = leaves[saved...].map { "\($0.position)\t\($0.hash.hexString)" }
            try Self.appendLines(lines, to: leavesDir.appendingPathComponent("\(tree).log"))
        }

        // Append new nullifiers.
        if orderedNullifiersList.count > savedNullifierCountValue {
            let lines = orderedNullifiersList[savedNullifierCountValue...]
                .map { String($0, radix: 16) }
            try Self.appendLines(lines, to: directoryURL.appendingPathComponent("nullifiers.log"))
        }

        // Append new nullifier→txid mappings.
        if orderedNullifierTxidsList.count > savedNullifierTxidCountValue {
            let lines = orderedNullifierTxidsList[savedNullifierTxidCountValue...].map {
                "\(String($0.nullifier, radix: 16))\t\($0.txid.hexString)"
            }
            try Self.appendLines(lines, to: directoryURL.appendingPathComponent("nullifier-txids.log"))
        }

        // Rewrite utxos.json — small, but mutable due to isSpent / balanceBucket.
        let utxosData = try JSONEncoder().encode(utxos.map(SerializedUTXO.init))
        try utxosData.write(
            to: directoryURL.appendingPathComponent("utxos.json"),
            options: .atomic
        )

        // Rewrite meta.json LAST — its lastScannedBlock anchors what data must
        // be present in the log files.
        let meta = ScannerMeta(version: Self.persistenceVersion, lastScannedBlock: lastScannedBlock)
        let metaData = try JSONEncoder().encode(meta)
        try metaData.write(
            to: directoryURL.appendingPathComponent("meta.json"),
            options: .atomic
        )

        markSaved()

        // Clean up legacy single-file format if we just migrated.
        let legacyURL = directoryURL.deletingPathExtension()
            .appendingPathExtension("json")
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// Load scanner state. Prefers the new directory format; falls back to the
    /// legacy `{name}.json` file alongside the directory if present.
    public func load(from directoryURL: URL) throws {
        let metaURL = directoryURL.appendingPathComponent("meta.json")
        if FileManager.default.fileExists(atPath: metaURL.path) {
            try loadFromDirectory(directoryURL)
            return
        }
        let legacyURL = directoryURL.deletingPathExtension()
            .appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try loadLegacy(from: legacyURL)
            return
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadFromDirectory(_ directoryURL: URL) throws {
        let metaData = try Data(contentsOf: directoryURL.appendingPathComponent("meta.json"))
        let meta = try JSONDecoder().decode(ScannerMeta.self, from: metaData)

        let utxosData = try Data(contentsOf: directoryURL.appendingPathComponent("utxos.json"))
        let utxos = try JSONDecoder()
            .decode([SerializedUTXO].self, from: utxosData)
            .compactMap { $0.toUTXO() }

        let orderedNullifiers = Self.readLines(
            at: directoryURL.appendingPathComponent("nullifiers.log")
        )
        .compactMap { BigUInt($0, radix: 16) }

        let orderedTxids: [(nullifier: BigUInt, txid: Data)] = Self.readLines(
            at: directoryURL.appendingPathComponent("nullifier-txids.log")
        )
        .compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let n = BigUInt(parts[0], radix: 16),
                  let txid = Data(hexString: String(parts[1])) else { return nil }
            return (nullifier: n, txid: txid)
        }

        var pendingLeaves: [Int: [(position: Int, hash: Data)]] = [:]
        let leavesDir = directoryURL.appendingPathComponent("pending-leaves", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: leavesDir,
            includingPropertiesForKeys: nil
        ) {
            for fileURL in entries where fileURL.pathExtension == "log" {
                guard let tree = Int(fileURL.deletingPathExtension().lastPathComponent) else { continue }
                let leaves: [(position: Int, hash: Data)] = Self.readLines(at: fileURL)
                    .compactMap { line in
                        let parts = line.split(separator: "\t", maxSplits: 1)
                        guard parts.count == 2,
                              let pos = Int(parts[0]),
                              let hash = Data(hexString: String(parts[1])) else { return nil }
                        return (position: pos, hash: hash)
                    }
                pendingLeaves[tree] = leaves
            }
        }

        restoreState(
            lastScannedBlock: meta.lastScannedBlock,
            utxos: utxos,
            orderedNullifiers: orderedNullifiers,
            orderedNullifierTxids: orderedTxids,
            pendingLeaves: pendingLeaves,
            markAsSaved: true
        )
    }

    private func loadLegacy(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(LegacyScannerState.self, from: data)

        let utxos = state.utxos.compactMap { $0.toUTXO() }

        // Legacy nullifiers were stored as a Set (no order); the array order
        // here is whatever JSONDecoder gave us, which is fine for membership.
        let orderedNullifiers = state.nullifiers.compactMap { BigUInt($0, radix: 16) }

        let orderedTxids: [(nullifier: BigUInt, txid: Data)]
        if let raw = state.nullifierTxids {
            orderedTxids = raw.compactMap { (k, v) in
                guard let n = BigUInt(k, radix: 16),
                      let txid = Data(hexString: v) else { return nil }
                return (nullifier: n, txid: txid)
            }
        } else {
            orderedTxids = []
        }

        let pendingLeaves: [Int: [(position: Int, hash: Data)]] = state.pendingLeaves.mapValues { leaves in
            leaves.compactMap { l in
                guard let hash = Data(hexString: l.hash) else { return nil }
                return (position: l.position, hash: hash)
            }
        }

        restoreState(
            lastScannedBlock: state.lastScannedBlock,
            utxos: utxos,
            orderedNullifiers: orderedNullifiers,
            orderedNullifierTxids: orderedTxids,
            pendingLeaves: pendingLeaves,
            markAsSaved: false  // first save will fully populate the new directory layout
        )
    }

    // MARK: - Append helpers

    private static func appendLines(_ lines: [String], to url: URL) throws {
        guard !lines.isEmpty else { return }
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: url)
        }
    }

    private static func readLines(at url: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

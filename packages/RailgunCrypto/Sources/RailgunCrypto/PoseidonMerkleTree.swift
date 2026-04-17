import BigInt

/// A depth-16 binary Merkle tree using Poseidon hashing over the BN254 field.
///
/// Matches the RAILGUN engine's merkle tree implementation:
/// - 65,536 (2^16) max leaves per tree
/// - Empty nodes filled with precomputed "zero values" at each level
/// - Zero value at level 0 = keccak256("Railgun") % SNARK_PRIME
/// - Zero value at level N = poseidon(zero[N-1], zero[N-1])
public struct PoseidonMerkleTree: Sendable {
    public static let depth = 16
    public static let maxLeaves = 1 << depth // 65,536

    /// Precomputed zero values for each level (0 = leaf, 16 = root).
    public static let zeros: [BigUInt] = {
        var z = [BigUInt](repeating: 0, count: depth + 1)
        // keccak256("Railgun") % SNARK_PRIME
        z[0] = BigUInt("0488f89b25bc7011eaf6a5edce71aeafb9fe706faa3c0a5cd9cbe868ae3b9ffc", radix: 16)!
        for level in 1...depth {
            z[level] = Poseidon.hash(z[level - 1], z[level - 1])
        }
        return z
    }()

    /// Node storage: nodes[level][index] = hash.
    /// Level 0 = leaves, level 16 = root.
    /// Only stores non-zero nodes (sparse).
    private var nodes: [Int: [Int: BigUInt]]

    /// Number of leaves inserted.
    public private(set) var count: Int

    public init() {
        self.nodes = [:]
        self.count = 0
    }

    /// The current root hash.
    public var root: BigUInt {
        nodeHash(level: Self.depth, index: 0)
    }

    /// Get the hash at a specific (level, index), falling back to the zero value.
    public func nodeHash(level: Int, index: Int) -> BigUInt {
        nodes[level]?[index] ?? Self.zeros[level]
    }

    /// Insert a single leaf at the next available position.
    /// Returns the position the leaf was inserted at.
    @discardableResult
    public mutating func insertLeaf(_ leaf: BigUInt) -> Int {
        precondition(count < Self.maxLeaves, "Tree is full")
        let position = count
        setNode(level: 0, index: position, hash: leaf)
        rebuildPath(from: position)
        count += 1
        return position
    }

    /// Insert a batch of leaves starting at the next available position.
    /// More efficient than inserting one-by-one because shared parent nodes
    /// are only recomputed once.
    public mutating func insertLeaves(_ leaves: [BigUInt]) {
        precondition(count + leaves.count <= Self.maxLeaves, "Tree overflow")
        let startPosition = count
        for (i, leaf) in leaves.enumerated() {
            setNode(level: 0, index: startPosition + i, hash: leaf)
        }
        count += leaves.count
        // Rebuild all affected paths
        rebuildPaths(from: startPosition, to: startPosition + leaves.count - 1)
    }

    /// Generate a Merkle proof for the leaf at the given position.
    public func merkleProof(index: Int) -> MerkleProof {
        precondition(index < count, "Index \(index) out of range (count: \(count))")

        let leaf = nodeHash(level: 0, index: index)
        var elements = [BigUInt]()
        var currentIndex = index

        for level in 0..<Self.depth {
            // Sibling is at index XOR 1
            let siblingIndex = currentIndex ^ 1
            elements.append(nodeHash(level: level, index: siblingIndex))
            currentIndex >>= 1
        }

        return MerkleProof(
            leaf: leaf,
            elements: elements,
            leafIndex: index,
            root: root
        )
    }

    // MARK: - Private

    private mutating func setNode(level: Int, index: Int, hash: BigUInt) {
        if nodes[level] == nil {
            nodes[level] = [:]
        }
        nodes[level]![index] = hash
    }

    /// Rebuild internal nodes along the path from a leaf to the root.
    private mutating func rebuildPath(from leafIndex: Int) {
        var index = leafIndex
        for level in 0..<Self.depth {
            let parentIndex = index >> 1
            let leftChild = nodeHash(level: level, index: parentIndex * 2)
            let rightChild = nodeHash(level: level, index: parentIndex * 2 + 1)
            let parentHash = Poseidon.hash(leftChild, rightChild)
            setNode(level: level + 1, index: parentIndex, hash: parentHash)
            index = parentIndex
        }
    }

    /// Rebuild internal nodes for a range of leaf insertions.
    /// Collects affected parent indices at each level to avoid redundant hashing.
    private mutating func rebuildPaths(from startLeaf: Int, to endLeaf: Int) {
        var affectedIndices = Set<Int>()
        for i in startLeaf...endLeaf {
            affectedIndices.insert(i >> 1)
        }

        for level in 0..<Self.depth {
            var nextAffected = Set<Int>()
            for parentIndex in affectedIndices {
                let leftChild = nodeHash(level: level, index: parentIndex * 2)
                let rightChild = nodeHash(level: level, index: parentIndex * 2 + 1)
                let parentHash = Poseidon.hash(leftChild, rightChild)
                setNode(level: level + 1, index: parentIndex, hash: parentHash)
                nextAffected.insert(parentIndex >> 1)
            }
            affectedIndices = nextAffected
        }
    }
}

/// A Merkle inclusion proof for a leaf in a Poseidon tree.
public struct MerkleProof: Sendable {
    /// The leaf hash.
    public let leaf: BigUInt
    /// Sibling hashes from level 0 (leaf level) to level 15.
    /// elements[i] is the sibling at level i on the path from leaf to root.
    public let elements: [BigUInt]
    /// The leaf's index in the tree. The binary representation encodes the
    /// path direction at each level (0 = left, 1 = right).
    public let leafIndex: Int
    /// The tree root at the time the proof was generated.
    public let root: BigUInt

    /// Verify this proof: recompute the root from the leaf and siblings.
    public func verify() -> Bool {
        var current = leaf
        var index = leafIndex
        for element in elements {
            if index & 1 == 0 {
                current = Poseidon.hash(current, element)
            } else {
                current = Poseidon.hash(element, current)
            }
            index >>= 1
        }
        return current == root
    }
}

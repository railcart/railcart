import Testing
import BigInt
@testable import RailcartCrypto

@Suite("Poseidon Merkle Tree")
struct MerkleTreeTests {
    // MARK: - Zero values

    @Test("Zero value at level 0 is keccak256('Railgun') mod SNARK_PRIME")
    func zeroValueLevel0() {
        let expected = BigUInt("0488f89b25bc7011eaf6a5edce71aeafb9fe706faa3c0a5cd9cbe868ae3b9ffc", radix: 16)!
        #expect(PoseidonMerkleTree.zeros[0] == expected)
    }

    @Test("Zero values match SDK levels 1-4")
    func zeroValueLevels() {
        let expected: [BigUInt] = [
            BigUInt("01c405064436affeae1fc8e30b2e417b4243bbb819adca3b55bb32efc3e43a4f", radix: 16)!,
            BigUInt("0888d37652d10d1781db54b70af87b42a2916e87118f507218f9a42a58e85ed2", radix: 16)!,
            BigUInt("183f531ead7217ebc316b4c02a2aad5ad87a1d56d4fb9ed81bf84f644549eaf5", radix: 16)!,
            BigUInt("093c48f1ecedf2baec231f0af848a57a76c6cf05b290a396707972e1defd17df", radix: 16)!,
        ]
        for (i, exp) in expected.enumerated() {
            #expect(PoseidonMerkleTree.zeros[i + 1] == exp, "Level \(i + 1) mismatch")
        }
    }

    // MARK: - Empty tree

    @Test("Empty tree root matches SDK")
    func emptyTreeRoot() {
        let tree = PoseidonMerkleTree()
        let expected = BigUInt("14fceeac99eb8419a2796d1958fc2050d489bf5a3eb170ef16a667060344ba90", radix: 16)!
        #expect(tree.root == expected)
    }

    @Test("Empty tree has count 0")
    func emptyTreeCount() {
        let tree = PoseidonMerkleTree()
        #expect(tree.count == 0)
    }

    // MARK: - Leaf insertion

    @Test("Insert 3 leaves, root matches SDK")
    func insertThreeLeaves() {
        var tree = PoseidonMerkleTree()
        tree.insertLeaves([100, 200, 300])
        let expected = BigUInt("259404d4f8dcb52fb9f4238c87f485c5c7d58110d7d3ef7356f6d54314d02f33", radix: 16)!
        #expect(tree.root == expected)
        #expect(tree.count == 3)
    }

    @Test("Single insert matches batch insert")
    func singleVsBatchInsert() {
        var treeSingle = PoseidonMerkleTree()
        treeSingle.insertLeaf(100)
        treeSingle.insertLeaf(200)
        treeSingle.insertLeaf(300)

        var treeBatch = PoseidonMerkleTree()
        treeBatch.insertLeaves([100, 200, 300])

        #expect(treeSingle.root == treeBatch.root)
    }

    // MARK: - Merkle proofs

    @Test("Merkle proof for index 1 matches SDK")
    func merkleProofIndex1() {
        var tree = PoseidonMerkleTree()
        tree.insertLeaves([100, 200, 300])

        let proof = tree.merkleProof(index: 1)
        #expect(proof.leaf == BigUInt(200))
        #expect(proof.leafIndex == 1)

        // Level 0 sibling is leaf at index 0 (value 100 = 0x64)
        #expect(proof.elements[0] == BigUInt(100))

        // Level 1 sibling: poseidon(300, ZERO)
        let expectedLevel1 = BigUInt("12e5d1785b0f601b96767d955438ae87d629fa4672b30414910649c6b6596927", radix: 16)!
        #expect(proof.elements[1] == expectedLevel1)

        // Remaining siblings are zero values at their respective levels
        for level in 2..<16 {
            #expect(proof.elements[level] == PoseidonMerkleTree.zeros[level],
                    "Level \(level) sibling should be zero value")
        }
    }

    @Test("Merkle proof verifies")
    func proofVerification() {
        var tree = PoseidonMerkleTree()
        tree.insertLeaves([100, 200, 300])

        for i in 0..<3 {
            let proof = tree.merkleProof(index: i)
            #expect(proof.verify(), "Proof for index \(i) should verify")
        }
    }

    @Test("Proof root matches tree root")
    func proofRootMatchesTree() {
        var tree = PoseidonMerkleTree()
        tree.insertLeaves([42, 99, 1337, 0])

        let proof = tree.merkleProof(index: 2)
        #expect(proof.root == tree.root)
    }

    @Test("Proof with tampered leaf fails verification")
    func tamperedProofFails() {
        var tree = PoseidonMerkleTree()
        tree.insertLeaves([100, 200, 300])

        let proof = tree.merkleProof(index: 1)
        // Create a tampered proof with wrong leaf
        let tampered = MerkleProof(
            leaf: BigUInt(999),
            elements: proof.elements,
            leafIndex: proof.leafIndex,
            root: proof.root
        )
        #expect(!tampered.verify())
    }

    // MARK: - Tree properties

    @Test("Tree depth is 16")
    func treeDepth() {
        #expect(PoseidonMerkleTree.depth == 16)
    }

    @Test("Max leaves is 65536")
    func maxLeaves() {
        #expect(PoseidonMerkleTree.maxLeaves == 65536)
    }
}

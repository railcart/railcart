# RailcartCrypto — Native RAILGUN Scanner

Replace the Node.js SDK's balance/UTXO scanning with a native Swift implementation.
Keep proof generation (the hard part) in the SDK via the Node.js bridge.

## Why

The SDK's scanning is the source of most reliability issues — stale UTXO data,
missing blinded commitments, flaky incremental vs full rescan behavior.
Native scanning gives us full control over the data pipeline and eliminates
the round-trip through the bridge for the most latency-sensitive operations.

## Architecture

```
                    Swift (RailcartCrypto)                    Node.js (SDK)
┌─────────────────────────────────────────────┐    ┌──────────────────────────┐
│  Event Parsing (RPC / GraphQL quick-sync)   │    │                          │
│  Note Decryption (ECDH + AES/XChaCha20)     │    │  Proof Generation        │
│  Merkle Tree (Poseidon, depth 16)           │───▶│  (groth16 circuits)      │
│  UTXO Storage + Balance Tracking            │    │                          │
│  Merkle Proof Construction                  │    │  Transaction Population  │
│  POI Blinded Commitments                    │    │  Broadcaster Submission  │
└─────────────────────────────────────────────┘    └──────────────────────────┘
```

## Steps

### 1. Poseidon Hash ✅
- BN254 field arithmetic (add, mul, square, pow5)
- Hades permutation (8 full rounds + variable partial rounds)
- Round constants and MDS matrices for t=2,3,4,5
- Validated against circomlibjs test vectors and RAILGUN merkle zero values

### 2. Merkle Tree ✅
- Depth-16 Poseidon binary tree (max 65,536 leaves per tree)
- Zero-value initialization (keccak256("Railgun") % SNARK_PRIME)
- Leaf insertion (single + batch, with optimized batch path rebuild)
- Merkle proof generation with verification
- Validated: empty root, 3-leaf root, proof elements, proof verification all match SDK

### 3. Key Derivation ✅
- BIP32 with custom HMAC key "babyjubjub seed" (not standard "Bitcoin seed")
- Spending: m/44'/1984'/0'/0'/[index]' → BLAKE-512 → prune → BabyJubJub Base8 scalar mult
- Viewing: m/420'/1984'/0'/0'/[index]' → Ed25519 public key (CryptoKit)
- Nullifying: poseidon([viewingPrivateKey])
- Master public: poseidon([spendingPubX, spendingPubY, nullifyingKey])
- BLAKE-512 implemented from spec (original BLAKE, not BLAKE2)
- BabyJubJub twisted Edwards curve (A=168700, D=168696) with point add/scalar mul
- All outputs validated against SDK: spending pub, viewing pub, nullifying key, master pub key

### 4. Note Decryption ✅
- Ed25519 point arithmetic (decompress, add, scalar multiply) over GF(2^255-19)
- ECDH: SHA-512 → clamp → scalar mod l → Ed25519 point multiply → SHA-256
- AES-256-GCM decryption of V2 note ciphertexts
- Note parser: masterPublicKey, tokenHash, random, value, memo
- Receiver vs sender detection (try both blinded keys)
- All validated against SDK test vectors
- **Known issue**: Ed25519 BigUInt arithmetic is slow (~20s per ECDH). Needs native/C optimization for production scanning.

### 5. Event Parsing ✅
- QuickSync client fetches from RAILGUN V2 subgraph endpoints (Ethereum, Sepolia, BSC, Polygon, Arbitrum)
- Parses TransactCommitment (ciphertext with IV/tag/data/blinded keys), ShieldCommitment (preimage + encrypted bundle), Nullifier events, Unshield events
- Parallel fetch of commitments, nullifiers, unshields
- Paginated (limit 10000 per query) with startBlock filter
- Validated against live mainnet and Sepolia subgraphs

### 6. UTXO Model + Storage ✅
- UTXO struct with tree, position, hash, token, value, random, nullifier, spent flag
- Scanner orchestrator: QuickSync → decrypt → merkle tree insert → nullifier tracking
- Balance aggregation per token hash from spendable (non-spent, non-sent) UTXOs
- Merkle tree padding for non-owned commitments (correct root computation)
- Progress callbacks during scan
- In-memory storage (persistent storage deferred to integration step)

### 7. Proof Input Assembly ✅
- UTXO selection: greedy largest-first covering the spend amount
- ProofInputs struct with all fields matching PrivateInputsRailgun + PublicInputsRailgun
- Merkle proof retrieval for each selected UTXO
- Nullifier computation: poseidon([nullifyingKey, leafIndex])
- Output commitment hashes: poseidon([npk, tokenHash, value])
- JSON serialization for bridge transport (all BigUInt → 0x-prefixed 64-char hex)

### 8. Integration ✅
- RailcartCrypto added as local package dependency to Xcode project
- NativeScannerService wraps RailcartCrypto.Scanner with wallet key initialization
- BalanceService updated: uses native scanner instead of Node.js scanBalances/fullRescan
- Wallet mnemonic fetched via bridge at scan time, keys derived natively
- Scan progress forwarded to existing BalanceService observable properties
- Detailed progress messages: "Fetching events from block X...", "Decrypting commitments: X/Y", "Computing balances..."
- Proof generation still uses Node.js bridge (unchanged)
- Old Node.js scan event listener kept as fallback for SDK-initiated scans

## Crypto Primitives

| Primitive | Use | Swift Source |
|-----------|-----|-------------|
| Poseidon (BN254) | Merkle tree, nullifiers, note hash, key derivation | RailcartCrypto (implemented) |
| Ed25519 / X25519 | Viewing keys, ECDH shared secrets | CryptoKit |
| AES-256-GCM | V2 note decryption | CryptoKit |
| XChaCha20-Poly1305 | V3 note decryption | libsodium or manual (ChaCha20 + HChaCha20) |
| BabyJubJub | Spending keys, note public keys | Needs implementation or library |
| Keccak256 | MERKLE_ZERO_VALUE, address hashing | Existing in RailcartChain or CryptoKit |
| BIP32 / BIP39 | Mnemonic → master keys | Existing libraries |

## Parameters

- Merkle tree depth: 16
- Merkle tree max leaves: 65,536 per tree
- Poseidon S-box: x^5
- Poseidon full rounds: 8
- Poseidon partial rounds: [56, 57, 56, 60] for t=[2, 3, 4, 5]
- BN254 scalar field: 21888242871839275222246405745257275088548364400416034343698204186575808495617
- MERKLE_ZERO_VALUE: keccak256("Railgun") % SNARK_PRIME

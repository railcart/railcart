/**
 * Bridge methods for proof generation using externally-provided UTXO data
 * from the native Swift scanner. Bypasses SDK scanning entirely.
 */
import { registerMethod, sendEvent } from "./bridge.js";
import { chainForName } from "./chains.js";
import {
  TXIDVersion,
  NETWORK_CONFIG,
} from "@railgun-community/shared-models";
import {
  fullWalletForID,
  getProver,
} from "@railgun-community/wallet";
import {
  TransactNote,
  UnshieldNoteERC20,
  getTokenDataERC20,
  getTokenDataHashERC20,
  TokenType,
} from "@railgun-community/engine";

// Internal engine modules — resolve to absolute paths to bypass package "exports" restrictions.
import { createRequire } from "module";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
const __dirname = dirname(fileURLToPath(import.meta.url));
const engineDist = join(__dirname, "../node_modules/@railgun-community/engine/dist");
const _require = createRequire(join(engineDist, "dummy.js")); // CJS require relative to engine

const { getNoteBlindingKeys, getSharedSymmetricKey } = _require("./utils/keys-utils.js");
const { hashBoundParamsV2 } = _require("./transaction/bound-params.js");
const { ByteUtils } = _require("./utils/bytes.js");
const { getChainFullNetworkID } = _require("./chain/chain.js");
const { poseidon } = _require("./utils/poseidon.js");

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const HASH_ZERO = "0x0000000000000000000000000000000000000000000000000000000000000000";

export function registerNativeProofMethods() {
  /**
   * Generate an unshield proof using externally-provided UTXO data.
   * Bypasses SDK scanning — uses the native Swift scanner's UTXO selection
   * and merkle proofs, but still uses the SDK wallet for key ops, encryption,
   * signing, and the groth16 prover.
   *
   * params: {
   *   chainName: string,
   *   railgunWalletID: string,
   *   encryptionKey: string,
   *   toAddress: string,           // Public destination
   *   tokenAddress: string,        // ERC20 address
   *   amount: string,              // Amount to unshield (wei)
   *   treeNumber: number,          // Which merkle tree the UTXOs are in
   *   merkleRoot: string,          // Hex merkle root from native scanner
   *   utxos: [{                    // Selected UTXOs from native scanner
   *     value: string,             // Hex BigInt
   *     random: string,            // Hex 16 bytes
   *     leafIndex: number,
   *     pathElements: string[],    // Array of 16 hex sibling hashes
   *   }],
   *   // Optional broadcaster fee
   *   broadcasterFeeTokenAddress?: string,
   *   broadcasterFeeAmount?: string,
   *   broadcasterRailgunAddress?: string,
   *   overallBatchMinGasPrice?: string,
   *   sendWithPublicWallet?: boolean,
   * }
   */
  registerMethod("generateUnshieldProofNative", async (params) => {
    const {
      chainName, railgunWalletID, encryptionKey,
      toAddress, tokenAddress, amount,
      treeNumber, merkleRoot, utxos,
      broadcasterFeeTokenAddress, broadcasterFeeAmount, broadcasterRailgunAddress,
      overallBatchMinGasPrice,
      sendWithPublicWallet,
    } = params;

    const { chain, networkName } = chainForName(chainName);
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    // Get wallet for signing and key operations
    const wallet = fullWalletForID(railgunWalletID);
    const spendingKeyPair = await wallet.getSpendingKeyPair(encryptionKey);
    const nullifyingKey = wallet.getNullifyingKey();
    const viewingKeyPair = await wallet.getViewingKeyPair();
    const addressKeys = wallet.addressKeys;

    // Token data
    const tokenData = getTokenDataERC20(tokenAddress);
    const tokenHash = getTokenDataHashERC20(tokenAddress);

    const unshieldAmount = BigInt(amount);
    const totalIn = utxos.reduce((sum, u) => sum + BigInt(u.value), 0n);

    // Build outputs — IMPORTANT: internal outputs (change) FIRST, unshield LAST.
    // The circuit uses the `unshield` flag to treat the last output as a raw address.
    const outputs = [];
    const internalOutputs = []; // Only TransactNotes (need encryption)

    // 1. Change output first (back to self)
    let feeAmount = 0n;
    if (broadcasterFeeAmount && broadcasterRailgunAddress && BigInt(broadcasterFeeAmount) > 0n) {
      feeAmount = BigInt(broadcasterFeeAmount);
    }
    const change = totalIn - unshieldAmount - feeAmount;
    if (change > 0n) {
      const changeNote = TransactNote.createTransfer(
        addressKeys,     // receiver (self)
        addressKeys,     // sender (self)
        change,
        tokenData,
        true,            // showSenderAddressToRecipient
        2,               // OutputType.Change
        undefined,       // memoText
      );
      outputs.push(changeNote);
      internalOutputs.push(changeNote);
    }

    // 2. Unshield output LAST (public, no encryption)
    const unshieldNote = new UnshieldNoteERC20(
      toAddress,
      unshieldAmount,
      tokenData,
    );
    outputs.push(unshieldNote);

    // Encrypt internal outputs (change note)
    const commitmentCiphertext = [];
    for (const note of internalOutputs) {
      const blindedKeys = await getNoteBlindingKeys(
        viewingKeyPair.pubkey,
        note.receiverAddressData.viewingPublicKey,
        note.random,
        note.senderRandom,
      );

      const sharedKey = await getSharedSymmetricKey(
        viewingKeyPair.privateKey,
        blindedKeys.blindedReceiverViewingKey,
      );

      const { noteCiphertext, noteMemo, annotationData } = note.encryptV2(
        txidVersion,
        sharedKey,
        addressKeys.masterPublicKey,
        note.senderRandom,
        viewingKeyPair.privateKey,
      );

      commitmentCiphertext.push({
        ciphertext: [
          ByteUtils.hexlify(`${noteCiphertext.iv}${noteCiphertext.tag}`, true),
          ByteUtils.hexlify(noteCiphertext.data[0], true),
          ByteUtils.hexlify(noteCiphertext.data[1], true),
          ByteUtils.hexlify(noteCiphertext.data[2], true),
        ],
        blindedSenderViewingKey: ByteUtils.formatToByteLength(
          blindedKeys.blindedSenderViewingKey, 32, true),
        blindedReceiverViewingKey: ByteUtils.formatToByteLength(
          blindedKeys.blindedReceiverViewingKey, 32, true),
        memo: ByteUtils.hexlify(noteMemo || new Uint8Array(), true),
        annotationData: ByteUtils.hexlify(annotationData || new Uint8Array(), true),
      });
    }

    // Build BoundParams
    const unshieldFlag = 1; // UNSHIELD
    const minGasPrice = overallBatchMinGasPrice ? BigInt(overallBatchMinGasPrice) : 0n;

    const boundParams = {
      treeNumber,
      minGasPrice,
      unshield: unshieldFlag,
      chainID: ByteUtils.hexlify(getChainFullNetworkID(chain), true),
      adaptContract: ZERO_ADDRESS,
      adaptParams: HASH_ZERO,
      commitmentCiphertext,
    };

    const boundParamsHash = hashBoundParamsV2(boundParams);

    // Use the SDK wallet's merkle tree root (authoritative, matches on-chain)
    // instead of the native scanner's root which may differ.
    const sdkWallet = _require("./wallet/abstract-wallet.js");
    const txidMerkletree = wallet.getUTXOMerkletree
      ? wallet.getUTXOMerkletree(txidVersion, chain)
      : null;
    let effectiveMerkleRoot = BigInt(merkleRoot);
    let effectivePathElements = utxos.map(u => u.pathElements.map(e => BigInt(e)));

    if (txidMerkletree) {
      try {
        const sdkRoot = await txidMerkletree.getRoot(treeNumber);
        if (sdkRoot) {
          effectiveMerkleRoot = ByteUtils.hexToBigInt(sdkRoot);
          process.stderr.write(`[native-proof] Using SDK merkle root: ${sdkRoot}\n`);
          // Also get SDK's merkle proof for each UTXO
          const sdkPaths = await Promise.all(
            utxos.map(u => txidMerkletree.getMerkleProof(treeNumber, u.leafIndex))
          );
          effectivePathElements = sdkPaths.map(proof =>
            proof.elements.map(e => ByteUtils.hexToBigInt(e))
          );
        }
      } catch (e) {
        process.stderr.write(`[native-proof] SDK merkle tree unavailable, using native root: ${e.message}\n`);
      }
    }

    // Build nullifiers from native scanner UTXOs
    const nullifiers = utxos.map(u =>
      poseidon([nullifyingKey, BigInt(u.leafIndex)])
    );

    // Build commitment hashes for outputs.
    // NOTE: UnshieldNoteERC20 stores a zeroed tokenData internally, so its
    // .hash is wrong. Compute the unshield commitment hash directly.
    const { getNoteHash } = _require("./note/note-util.js");
    const commitmentsOut = outputs.map(note => {
      if (note instanceof UnshieldNoteERC20) {
        return getNoteHash(note.toAddress, tokenData, note.value);
      }
      return note.hash;
    });

    // Build public inputs
    const publicInputs = {
      merkleRoot: effectiveMerkleRoot,
      boundParamsHash,
      nullifiers,
      commitmentsOut,
    };

    // Sign
    const signature = await wallet.sign(publicInputs, encryptionKey);

    // Build private inputs using native scanner merkle proofs
    const privateInputs = {
      tokenAddress: ByteUtils.hexToBigInt(tokenHash),
      publicKey: spendingKeyPair.pubkey,
      randomIn: utxos.map(u => BigInt(u.random)),
      valueIn: utxos.map(u => BigInt(u.value)),
      pathElements: effectivePathElements,
      leavesIndices: utxos.map(u => BigInt(u.leafIndex)),
      nullifyingKey,
      npkOut: outputs.map(note => note.notePublicKey),
      valueOut: outputs.map(note => note.value),
    };

    // Assemble unproved transaction inputs
    const unprovedTransactionInputs = {
      txidVersion,
      privateInputs,
      publicInputs,
      boundParams,
      signature: [...signature.R8, signature.S],
    };

    process.stderr.write(`[native-proof] Generating proof: ${privateInputs.randomIn.length} inputs, ${outputs.length} outputs\n`);

    // Generate proof
    const prover = getProver();

    let proof;
    try {
      const result = await prover.proveRailgun(
        txidVersion,
        unprovedTransactionInputs,
        (progress) => {
          sendEvent("proofProgress", { progress });
        },
      );
      proof = result.proof;
    } catch (proveErr) {
      process.stderr.write(`[native-proof] Proof generation failed: ${proveErr.message}\n`);
      if (proveErr.cause) process.stderr.write(`[native-proof] Cause: ${proveErr.cause.message || proveErr.cause}\n`);
      throw proveErr;
    }

    // Build the transaction using the SDK's generateTransact
    const { RailgunVersionedSmartContracts } = _require("./contracts/railgun-smart-wallet/railgun-versioned-smart-contracts.js");
    const { Prover: ProverClass } = await import("@railgun-community/engine");

    // Format the proved transaction struct the same way the SDK does
    const formattedProof = ProverClass.formatProof(proof);

    const txStruct = {
      proof: formattedProof,
      merkleRoot: ByteUtils.nToHex(publicInputs.merkleRoot, 32, true),
      nullifiers: nullifiers.map(n => ByteUtils.nToHex(n, 32, true)),
      commitments: commitmentsOut.map(c => ByteUtils.nToHex(c, 32, true)),
      boundParams,
      unshieldPreimage: {
        npk: ByteUtils.formatToByteLength(toAddress, 32, true),
        token: tokenData,
        value: unshieldAmount,
      },
    };

    const transaction = await RailgunVersionedSmartContracts.generateTransact(
      txidVersion,
      chain,
      [txStruct],
    );

    return {
      transaction: {
        to: transaction.to,
        data: transaction.data,
        value: transaction.value?.toString() ?? "0",
      },
    };
  });
}

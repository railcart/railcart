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
const { decodeAddress } = _require("./key-derivation/bech32.js");

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

    // Build outputs — broadcaster fee FIRST, change second, unshield LAST.
    // The broadcaster expects its fee as the first commitment.
    // The circuit uses the `unshield` flag to treat the last output as a raw address.
    const outputs = [];
    const internalOutputs = []; // Only TransactNotes (need encryption)

    let feeAmount = 0n;
    if (broadcasterFeeAmount && broadcasterRailgunAddress && BigInt(broadcasterFeeAmount) > 0n) {
      feeAmount = BigInt(broadcasterFeeAmount);
    }
    if (!sendWithPublicWallet && broadcasterRailgunAddress && feeAmount === 0n) {
      throw new Error(`Broadcaster fee is 0 — cannot create fee note. broadcasterFeeAmount=${broadcasterFeeAmount}`);
    }

    // 1. Broadcaster fee note FIRST (broadcaster expects it as the first commitment)
    if (feeAmount > 0n && broadcasterRailgunAddress) {
      const broadcasterAddressData = decodeAddress(broadcasterRailgunAddress);
      const feeNote = TransactNote.createTransfer(
        broadcasterAddressData, // receiver (broadcaster)
        addressKeys,            // sender (self)
        feeAmount,
        tokenData,
        false,                  // showSenderAddressToRecipient — never for broadcaster fees
        1,                      // OutputType.BroadcasterFee
        undefined,              // memoText
      );
      outputs.push(feeNote);
      internalOutputs.push(feeNote);
    }

    // 2. Change output (back to self)
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

    // 3. Unshield output LAST (public, no encryption)
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

    // Use native scanner's merkle root and proofs directly.
    // The SDK tree is not scanned (only the native scanner runs), so SDK
    // proofs are stale and unreliable.
    const effectiveMerkleRoot = BigInt(merkleRoot);
    const effectivePathElements = utxos.map(u => u.pathElements.map(e => BigInt(e)));
    process.stderr.write(`[native-proof] Using native merkle root: ${merkleRoot}\n`);

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

    // Generate pre-transaction POIs (required by broadcasters on mainnet)
    let preTransactionPOIsPerTxidLeafPerList = {};
    if (!sendWithPublicWallet) {
      const { POI } = _require("./poi/poi.js");
      const { BlindedCommitment } = _require("./poi/blinded-commitment.js");
      const { getGlobalTreePosition } = _require("./poi/global-tree-position.js");

      const activeListKeys = POI.getActiveListKeys();
      if (activeListKeys.length > 0) {
        // Build mock TXO objects matching the SDK's expected shape.
        // notePublicKey = poseidon(masterPublicKey, random)
        const txos = utxos.map(u => {
          const globalPos = getGlobalTreePosition(treeNumber, u.leafIndex);
          const npk = poseidon([addressKeys.masterPublicKey, BigInt(u.random)]);
          return {
            blindedCommitment: BlindedCommitment.getForShieldOrTransact(
              ByteUtils.nToHex(BigInt(u.commitmentHash), 32, true),
              npk,
              globalPos,
            ),
            note: {
              tokenHash: tokenHash,
              random: u.random,
              value: BigInt(u.value),
            },
            position: u.leafIndex,
            tree: treeNumber,
          };
        });

        for (const listKey of activeListKeys) {
          preTransactionPOIsPerTxidLeafPerList[listKey] ??= {};
          const { txidLeafHash, preTransactionPOI } =
            await wallet.generatePreTransactionPOI(
              txidVersion, chain, listKey, txos,
              publicInputs, privateInputs, treeNumber,
              true, // hasUnshield
              () => {},
            );
          preTransactionPOIsPerTxidLeafPerList[listKey][txidLeafHash] = preTransactionPOI;
        }
        process.stderr.write(`[native-proof] Generated POIs for ${activeListKeys.length} list(s)\n`);
      }
    }

    return {
      transaction: {
        to: transaction.to,
        data: transaction.data,
        value: transaction.value?.toString() ?? "0",
      },
      nullifiers: nullifiers.map(n => ByteUtils.nToHex(n, 32, true)),
      preTransactionPOIsPerTxidLeafPerList,
    };
  });

  /**
   * Generate a private-to-private transfer proof using externally-provided
   * UTXO data from the native Swift scanner. Mirrors generateUnshieldProofNative
   * but the last output is a TransactNote to the recipient (not an unshield),
   * `unshield = 0`, and there is no unshieldPreimage.
   *
   * params: {
   *   chainName, railgunWalletID, encryptionKey,
   *   recipientRailgunAddress,   // 0zk address
   *   tokenAddress, amount,
   *   treeNumber, merkleRoot, utxos,  // from native scanner
   *   // Optional broadcaster fee
   *   broadcasterFeeTokenAddress?, broadcasterFeeAmount?, broadcasterRailgunAddress?,
   *   overallBatchMinGasPrice?,
   *   sendWithPublicWallet?,
   * }
   */
  registerMethod("generateTransferProofNative", async (params) => {
    const {
      chainName, railgunWalletID, encryptionKey,
      recipientRailgunAddress,
      tokenAddress, amount,
      treeNumber, merkleRoot, utxos,
      broadcasterFeeAmount, broadcasterRailgunAddress,
      overallBatchMinGasPrice,
      sendWithPublicWallet,
    } = params;

    const { chain } = chainForName(chainName);
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const wallet = fullWalletForID(railgunWalletID);
    const spendingKeyPair = await wallet.getSpendingKeyPair(encryptionKey);
    const nullifyingKey = wallet.getNullifyingKey();
    const viewingKeyPair = await wallet.getViewingKeyPair();
    const addressKeys = wallet.addressKeys;

    const tokenData = getTokenDataERC20(tokenAddress);
    const tokenHash = getTokenDataHashERC20(tokenAddress);

    const transferAmount = BigInt(amount);
    const totalIn = utxos.reduce((sum, u) => sum + BigInt(u.value), 0n);

    const recipientAddressData = decodeAddress(recipientRailgunAddress);

    let feeAmount = 0n;
    if (broadcasterFeeAmount && broadcasterRailgunAddress && BigInt(broadcasterFeeAmount) > 0n) {
      feeAmount = BigInt(broadcasterFeeAmount);
    }
    if (!sendWithPublicWallet && broadcasterRailgunAddress && feeAmount === 0n) {
      throw new Error(`Broadcaster fee is 0 — cannot create fee note. broadcasterFeeAmount=${broadcasterFeeAmount}`);
    }

    // Value conservation — selected UTXOs must cover transfer + fee.
    // Catches caller bugs (e.g. sending the combined amount as `amount`)
    // before they silently produce a note with the wrong value.
    if (totalIn < transferAmount + feeAmount) {
      throw new Error(
        `Selected UTXOs (${totalIn}) do not cover transfer (${transferAmount}) + broadcaster fee (${feeAmount})`
      );
    }
    process.stderr.write(
      `[native-transfer] totalIn=${totalIn} transfer=${transferAmount} fee=${feeAmount} change=${totalIn - transferAmount - feeAmount}\n`
    );

    // Outputs: broadcaster fee FIRST (if any), recipient transfer, change back to self.
    // All outputs are TransactNotes, so every output needs encryption.
    const outputs = [];

    if (feeAmount > 0n && broadcasterRailgunAddress) {
      const broadcasterAddressData = decodeAddress(broadcasterRailgunAddress);
      const feeNote = TransactNote.createTransfer(
        broadcasterAddressData, // receiver (broadcaster)
        addressKeys,            // sender (self)
        feeAmount,
        tokenData,
        false,                  // showSenderAddressToRecipient — never for broadcaster fees
        1,                      // OutputType.BroadcasterFee
        undefined,              // memoText
      );
      outputs.push(feeNote);
    }

    const transferNote = TransactNote.createTransfer(
      recipientAddressData, // receiver (recipient)
      addressKeys,          // sender (self)
      transferAmount,
      tokenData,
      false,                // showSenderAddressToRecipient
      0,                    // OutputType.Transfer
      undefined,            // memoText
    );
    outputs.push(transferNote);

    const change = totalIn - transferAmount - feeAmount;
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
    }

    // Encrypt every output (all are TransactNotes)
    const commitmentCiphertext = [];
    for (const note of outputs) {
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

    // Transfer: unshield flag = 0 (no raw-address output)
    const unshieldFlag = 0;
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

    const effectiveMerkleRoot = BigInt(merkleRoot);
    const effectivePathElements = utxos.map(u => u.pathElements.map(e => BigInt(e)));
    process.stderr.write(`[native-transfer] Using native merkle root: ${merkleRoot}\n`);

    const nullifiers = utxos.map(u =>
      poseidon([nullifyingKey, BigInt(u.leafIndex)])
    );

    // All outputs are TransactNotes — commitment hashes come from .hash directly.
    const commitmentsOut = outputs.map(note => note.hash);

    const publicInputs = {
      merkleRoot: effectiveMerkleRoot,
      boundParamsHash,
      nullifiers,
      commitmentsOut,
    };

    const signature = await wallet.sign(publicInputs, encryptionKey);

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

    const unprovedTransactionInputs = {
      txidVersion,
      privateInputs,
      publicInputs,
      boundParams,
      signature: [...signature.R8, signature.S],
    };

    process.stderr.write(`[native-transfer] Generating proof: ${privateInputs.randomIn.length} inputs, ${outputs.length} outputs\n`);

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
      process.stderr.write(`[native-transfer] Proof generation failed: ${proveErr.message}\n`);
      if (proveErr.cause) process.stderr.write(`[native-transfer] Cause: ${proveErr.cause.message || proveErr.cause}\n`);
      throw proveErr;
    }

    const { RailgunVersionedSmartContracts } = _require("./contracts/railgun-smart-wallet/railgun-versioned-smart-contracts.js");
    const { Prover: ProverClass } = await import("@railgun-community/engine");

    const formattedProof = ProverClass.formatProof(proof);

    // No unshieldPreimage for a pure transfer — pass a zeroed placeholder
    // matching the contract's expected struct shape.
    const txStruct = {
      proof: formattedProof,
      merkleRoot: ByteUtils.nToHex(publicInputs.merkleRoot, 32, true),
      nullifiers: nullifiers.map(n => ByteUtils.nToHex(n, 32, true)),
      commitments: commitmentsOut.map(c => ByteUtils.nToHex(c, 32, true)),
      boundParams,
      unshieldPreimage: {
        npk: HASH_ZERO,
        token: {
          tokenType: TokenType.ERC20,
          tokenAddress: ZERO_ADDRESS,
          tokenSubID: 0n,
        },
        value: 0n,
      },
    };

    const transaction = await RailgunVersionedSmartContracts.generateTransact(
      txidVersion,
      chain,
      [txStruct],
    );

    let preTransactionPOIsPerTxidLeafPerList = {};
    if (!sendWithPublicWallet) {
      const { POI } = _require("./poi/poi.js");
      const { BlindedCommitment } = _require("./poi/blinded-commitment.js");
      const { getGlobalTreePosition } = _require("./poi/global-tree-position.js");

      const activeListKeys = POI.getActiveListKeys();
      if (activeListKeys.length > 0) {
        const txos = utxos.map(u => {
          const globalPos = getGlobalTreePosition(treeNumber, u.leafIndex);
          const npk = poseidon([addressKeys.masterPublicKey, BigInt(u.random)]);
          return {
            blindedCommitment: BlindedCommitment.getForShieldOrTransact(
              ByteUtils.nToHex(BigInt(u.commitmentHash), 32, true),
              npk,
              globalPos,
            ),
            note: {
              tokenHash: tokenHash,
              random: u.random,
              value: BigInt(u.value),
            },
            position: u.leafIndex,
            tree: treeNumber,
          };
        });

        for (const listKey of activeListKeys) {
          preTransactionPOIsPerTxidLeafPerList[listKey] ??= {};
          const { txidLeafHash, preTransactionPOI } =
            await wallet.generatePreTransactionPOI(
              txidVersion, chain, listKey, txos,
              publicInputs, privateInputs, treeNumber,
              false, // hasUnshield — pure transfer
              () => {},
            );
          preTransactionPOIsPerTxidLeafPerList[listKey][txidLeafHash] = preTransactionPOI;
        }
        process.stderr.write(`[native-transfer] Generated POIs for ${activeListKeys.length} list(s)\n`);
      }
    }

    return {
      transaction: {
        to: transaction.to,
        data: transaction.data,
        value: transaction.value?.toString() ?? "0",
      },
      nullifiers: nullifiers.map(n => ByteUtils.nToHex(n, 32, true)),
      preTransactionPOIsPerTxidLeafPerList,
    };
  });
}

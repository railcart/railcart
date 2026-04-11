import { registerMethod, sendEvent } from "./bridge.js";
import { chainForName, CHAINS } from "./chains.js";
import { isEngineInitialized } from "./engine-init.js";
import {
  createRailgunWallet,
  loadWalletByID,
  walletForID,
  getRailgunAddress,
  populateShield,
  populateShieldBaseToken,
  getSerializedERC20Balances,
  getFallbackProviderForNetwork,
  rescanFullUTXOMerkletreesAndWallets,
  refreshBalances,
  generateUnshieldBaseTokenProof,
  populateProvedUnshieldBaseToken,
  gasEstimateForUnprovenUnshieldBaseToken,
  getWalletMnemonic,
} from "@railgun-community/wallet";
import crypto from "crypto";
import {
  TXIDVersion,
  NETWORK_CONFIG,
} from "@railgun-community/shared-models";
import { Wallet as EthersWallet, HDNodeWallet, Mnemonic } from "ethers";

function requireEngine() {
  if (!isEngineInitialized()) {
    throw new Error("Engine not initialized. Call initEngine first.");
  }
}

/**
 * Derive the standard Ethereum key from a mnemonic (BIP-44 m/44'/60'/0'/0/index).
 */
function deriveEthKey(mnemonic, index = 0) {
  const mnemonicObj = Mnemonic.fromPhrase(mnemonic);
  const wallet = HDNodeWallet.fromMnemonic(mnemonicObj, `m/44'/60'/0'/0/${index}`);
  return { address: wallet.address, privateKey: wallet.privateKey };
}

/**
 * Serialize an ethers ContractTransaction for JSON transport.
 */
function serializeTransaction(tx) {
  return {
    to: tx.to,
    data: tx.data,
    value: tx.value?.toString() ?? "0",
    gasLimit: tx.gasLimit?.toString(),
    chainId: tx.chainId?.toString(),
  };
}

export { serializeTransaction };

function parseScanParams(params) {
  requireEngine();
  const { chainName, railgunWalletID, railgunWalletIDs } = params;
  const { chain } = chainForName(chainName);
  const walletFilter = railgunWalletIDs?.length
    ? railgunWalletIDs
    : railgunWalletID
      ? [railgunWalletID]
      : undefined;
  return { chainName, chain, walletFilter };
}

export function registerWalletMethods() {
  /**
   * Validate a BIP-39 mnemonic phrase.
   *
   * params: { mnemonic: string }
   */
  registerMethod("validateMnemonic", async (params) => {
    const { mnemonic } = params;
    if (!mnemonic) throw new Error("mnemonic is required");

    const words = mnemonic.trim().split(/\s+/);
    if (![12, 15, 18, 21, 24].includes(words.length)) {
      return { valid: false, error: `Expected 12, 15, 18, 21, or 24 words, got ${words.length}.` };
    }

    // Check each word against the BIP-39 English wordlist
    const wordlist = Mnemonic.fromPhrase(
      "abandon ".repeat(11) + "about"
    ).wordlist;
    for (const word of words) {
      if (wordlist.getWordIndex(word) === -1) {
        return { valid: false, error: `"${word}" is not a valid BIP-39 word.` };
      }
    }

    try {
      Mnemonic.fromPhrase(words.join(" "));
      return { valid: true };
    } catch {
      return { valid: false, error: "Invalid checksum. Check that your words are in the correct order." };
    }
  });

  /**
   * Generate a new BIP-39 mnemonic phrase.
   */
  registerMethod("generateMnemonic", async () => {
    const wallet = EthersWallet.createRandom();
    return { mnemonic: wallet.mnemonic.phrase };
  });

  /**
   * Derive an encryption key from a password + salt using PBKDF2.
   *
   * params: { password: string, salt: string }
   */
  registerMethod("deriveEncryptionKey", async (params) => {
    const { password, salt } = params;
    if (!password || !salt) throw new Error("password and salt are required");
    const key = crypto.pbkdf2Sync(password, salt, 100000, 32, "sha256");
    return { encryptionKey: key.toString("hex") };
  });

  /**
   * Create a new RAILGUN wallet from a mnemonic.
   *
   * params: {
   *   encryptionKey: string,
   *   mnemonic: string,
   *   creationBlockNumbers?: Record<string, number>,
   * }
   */
  registerMethod("createWallet", async (params) => {
    requireEngine();
    const { encryptionKey, mnemonic, creationBlockNumbers, derivationIndex } = params;
    if (!encryptionKey || !mnemonic) {
      throw new Error("encryptionKey and mnemonic are required");
    }
    const index = derivationIndex ?? 0;
    // Convert our chainName keys (e.g. "ethereum") to SDK NetworkName keys (e.g. "Ethereum")
    const sdkBlockNumbers = {};
    if (creationBlockNumbers) {
      for (const [name, block] of Object.entries(creationBlockNumbers)) {
        const entry = CHAINS[name];
        if (entry) {
          sdkBlockNumbers[entry.networkName] = block;
        }
      }
    }
    const result = await createRailgunWallet(
      encryptionKey,
      mnemonic,
      sdkBlockNumbers,
      index,
    );
    const ethKey = deriveEthKey(mnemonic, index);
    return {
      id: result.id,
      railgunAddress: result.railgunAddress,
      ethAddress: ethKey.address,
      ethPrivateKey: ethKey.privateKey,
      derivationIndex: index,
    };
  });

  /**
   * Load an existing wallet by ID.
   *
   * params: { encryptionKey: string, railgunWalletID: string }
   */
  registerMethod("loadWallet", async (params) => {
    requireEngine();
    const { encryptionKey, railgunWalletID, derivationIndex } = params;
    if (!encryptionKey || !railgunWalletID) {
      throw new Error("encryptionKey and railgunWalletID are required");
    }
    const index = derivationIndex ?? 0;
    const result = await loadWalletByID(encryptionKey, railgunWalletID, false);
    const mnemonic = await getWalletMnemonic(encryptionKey, railgunWalletID);
    const ethKey = deriveEthKey(mnemonic, index);
    return {
      id: result.id,
      railgunAddress: result.railgunAddress,
      ethAddress: ethKey.address,
      ethPrivateKey: ethKey.privateKey,
      derivationIndex: index,
    };
  });

  /**
   * Get the mnemonic for a loaded wallet.
   *
   * params: { encryptionKey: string, railgunWalletID: string }
   */
  registerMethod("getWalletMnemonic", async (params) => {
    requireEngine();
    const { encryptionKey, railgunWalletID } = params;
    const mnemonic = await getWalletMnemonic(encryptionKey, railgunWalletID);
    return { mnemonic };
  });

  /**
   * Get the RAILGUN address for a loaded wallet.
   *
   * params: { railgunWalletID: string }
   */
  registerMethod("getRailgunAddress", async (params) => {
    requireEngine();
    const address = getRailgunAddress(params.railgunWalletID);
    if (!address) throw new Error("Wallet not loaded");
    return { railgunAddress: address };
  });

  /**
   * Derive an Ethereum key at a specific BIP-44 index from the wallet's mnemonic.
   *
   * params: { encryptionKey: string, railgunWalletID: string, index: number }
   */
  registerMethod("deriveEthereumKey", async (params) => {
    requireEngine();
    const { encryptionKey, railgunWalletID, index } = params;
    if (!encryptionKey || !railgunWalletID) {
      throw new Error("encryptionKey and railgunWalletID are required");
    }
    const mnemonic = await getWalletMnemonic(encryptionKey, railgunWalletID);
    const ethKey = deriveEthKey(mnemonic, index ?? 0);
    return { address: ethKey.address, privateKey: ethKey.privateKey, index: index ?? 0 };
  });

  /**
   * Get private token balances for a wallet on a chain.
   *
   * params: { railgunWalletID: string, chainName: string }
   */
  registerMethod("getBalances", async (params) => {
    requireEngine();
    const { railgunWalletID, chainName } = params;
    const { chain } = chainForName(chainName);
    const wallet = walletForID(railgunWalletID);
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;
    const balances = await wallet.getTokenBalances(txidVersion, chain, false);
    const serialized = getSerializedERC20Balances(balances);
    // Convert bigint amounts to strings for JSON
    const balanceList = serialized.map((b) => ({
      tokenAddress: b.tokenAddress,
      amount: b.amount.toString(),
    }));
    return { balances: balanceList, chainName };
  });

  /**
   * Incremental balance refresh — picks up where the last scan left off.
   * Use fullRescan for first-time or recovery scenarios.
   *
   * params: { chainName: string, railgunWalletID?: string, railgunWalletIDs?: string[] }
   */
  registerMethod("scanBalances", async (params) => {
    const { chainName, chain, walletFilter } = parseScanParams(params);

    process.stderr.write(`[sync] Starting incremental refresh for ${chainName} (chain ${chain.id})\n`);
    const startTime = Date.now();

    try {
      await refreshBalances(chain, walletFilter);
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      process.stderr.write(`[sync] Incremental refresh complete for ${chainName} in ${elapsed}s\n`);
    } catch (err) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      process.stderr.write(`[sync] Incremental refresh failed for ${chainName} after ${elapsed}s: ${err.message}\n`);
    }
    return { scanned: true, chainName };
  });

  /**
   * Full merkletree rescan — re-processes all local data from scratch.
   * Slow but thorough. Use for first-time setup or imported wallets.
   *
   * params: { chainName: string, railgunWalletID?: string, railgunWalletIDs?: string[] }
   */
  registerMethod("fullRescan", async (params) => {
    const { chainName, chain, walletFilter } = parseScanParams(params);

    process.stderr.write(`[sync] Starting full rescan for ${chainName} (chain ${chain.id})\n`);
    const startTime = Date.now();

    try {
      await rescanFullUTXOMerkletreesAndWallets(chain, walletFilter);
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      process.stderr.write(`[sync] Full rescan complete for ${chainName} in ${elapsed}s\n`);
    } catch (err) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      process.stderr.write(`[sync] Full rescan failed for ${chainName} after ${elapsed}s: ${err.message}\n`);
      // Fall back to incremental refresh
      process.stderr.write(`[sync] Falling back to refreshBalances for ${chainName}\n`);
      try {
        await refreshBalances(chain, walletFilter);
        const elapsed2 = ((Date.now() - startTime) / 1000).toFixed(1);
        process.stderr.write(`[sync] refreshBalances complete for ${chainName} in ${elapsed2}s\n`);
      } catch (refreshErr) {
        const elapsed2 = ((Date.now() - startTime) / 1000).toFixed(1);
        process.stderr.write(`[sync] refreshBalances fallback failed for ${chainName} after ${elapsed2}s: ${refreshErr.message}\n`);
      }
    }
    return { scanned: true, chainName };
  });

  /**
   * Get the current gas price for a chain.
   *
   * params: { chainName: string }
   */
  registerMethod("getGasPrice", async (params) => {
    requireEngine();
    const { chainName } = params;
    const { networkName } = chainForName(chainName);
    const provider = getFallbackProviderForNetwork(networkName);
    const feeData = await provider.getFeeData();
    return { gasPrice: (feeData.gasPrice || 0n).toString() };
  });

  /**
   * Get the ETH balance of a public address.
   *
   * params: { chainName: string, address: string }
   */
  registerMethod("getEthBalance", async (params) => {
    requireEngine();
    const { chainName, address } = params;
    const { networkName } = chainForName(chainName);
    const provider = getFallbackProviderForNetwork(networkName);
    const balance = await provider.getBalance(address);
    return { balance: balance.toString(), address };
  });

  /**
   * Get the current block number for a chain.
   *
   * params: { chainName: string }
   */
  registerMethod("getBlockNumber", async (params) => {
    requireEngine();
    const { chainName } = params;
    const { networkName } = chainForName(chainName);
    const provider = getFallbackProviderForNetwork(networkName);
    const blockNumber = await provider.getBlockNumber();
    return { blockNumber, chainName };
  });

  /**
   * Get ERC-20 token balances for an address.
   *
   * params: { chainName: string, address: string, tokenAddresses: string[] }
   */
  registerMethod("getERC20Balances", async (params) => {
    requireEngine();
    const { chainName, address, tokenAddresses } = params;
    if (!address || !tokenAddresses?.length) {
      throw new Error("address and tokenAddresses are required");
    }
    const { networkName } = chainForName(chainName);
    const provider = getFallbackProviderForNetwork(networkName);
    const balanceOfSelector = "0x70a08231";
    const balances = await Promise.all(
      tokenAddresses.map(async (tokenAddress) => {
        try {
          const paddedAddress = "0x" + address.slice(2).padStart(64, "0");
          const result = await provider.call({
            to: tokenAddress,
            data: balanceOfSelector + paddedAddress.slice(2),
          });
          return { tokenAddress, amount: BigInt(result).toString() };
        } catch {
          return { tokenAddress, amount: "0" };
        }
      })
    );
    return { balances };
  });

  /**
   * Shield base token (e.g. ETH → WETH → private).
   *
   * params: {
   *   chainName: string,
   *   railgunAddress: string,
   *   amount: string,          // in wei
   * }
   */
  registerMethod("shieldBaseToken", async (params) => {
    requireEngine();
    const { chainName, railgunAddress, amount } = params;
    if (!railgunAddress || !amount) {
      throw new Error("railgunAddress and amount are required");
    }
    const { networkName } = chainForName(chainName);
    const wrappedAddress = NETWORK_CONFIG[networkName].baseToken.wrappedAddress;
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    // Generate a random 32-byte shield private key
    const shieldPrivateKey = "0x" + crypto.randomBytes(32).toString("hex");

    const wrappedERC20Amount = {
      tokenAddress: wrappedAddress,
      amount: BigInt(amount),
    };

    const result = await populateShieldBaseToken(
      txidVersion,
      networkName,
      railgunAddress,
      shieldPrivateKey,
      wrappedERC20Amount,
    );

    return { transaction: serializeTransaction(result.transaction) };
  });

  /**
   * Generate an unshield proof for base token (e.g. private WETH → public ETH).
   * This is compute-intensive and emits progress events.
   *
   * params: {
   *   chainName: string,
   *   railgunWalletID: string,
   *   encryptionKey: string,
   *   publicWalletAddress: string,
   *   amount: string,  // in wei
   * }
   */
  registerMethod("generateUnshieldBaseTokenProof", async (params) => {
    requireEngine();
    const { chainName, railgunWalletID, encryptionKey, publicWalletAddress, amount } = params;
    const { networkName } = chainForName(chainName);
    const wrappedAddress = NETWORK_CONFIG[networkName].baseToken.wrappedAddress;
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const wrappedERC20Amount = {
      tokenAddress: wrappedAddress,
      amount: BigInt(amount),
    };

    await generateUnshieldBaseTokenProof(
      txidVersion,
      networkName,
      publicWalletAddress,
      railgunWalletID,
      encryptionKey,
      wrappedERC20Amount,
      undefined, // no broadcaster fee
      true,      // sendWithPublicWallet
      undefined, // no min gas price
      (progress, status) => {
        sendEvent("proofProgress", { progress, status });
      },
    );

    return { proved: true };
  });

  /**
   * Populate a proved unshield base token transaction.
   * Must call generateUnshieldBaseTokenProof first.
   *
   * params: {
   *   chainName: string,
   *   railgunWalletID: string,
   *   publicWalletAddress: string,
   *   amount: string,  // in wei
   * }
   */
  registerMethod("populateUnshieldBaseToken", async (params) => {
    requireEngine();
    const { chainName, railgunWalletID, publicWalletAddress, amount } = params;
    const { networkName } = chainForName(chainName);
    const wrappedAddress = NETWORK_CONFIG[networkName].baseToken.wrappedAddress;
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const wrappedERC20Amount = {
      tokenAddress: wrappedAddress,
      amount: BigInt(amount),
    };

    // Fetch current fee data to determine gas type
    const provider = getFallbackProviderForNetwork(networkName);
    const feeData = await provider.getFeeData();

    let gasDetails;
    if (feeData.maxFeePerGas != null) {
      // EIP-1559 (Type2)
      gasDetails = {
        evmGasType: 2,
        gasEstimate: 1500000n,
        maxFeePerGas: feeData.maxFeePerGas,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ?? 1000000000n,
      };
    } else {
      // Legacy (Type1)
      gasDetails = {
        evmGasType: 1,
        gasEstimate: 1500000n,
        gasPrice: feeData.gasPrice ?? 1000000000n,
      };
    }

    const result = await populateProvedUnshieldBaseToken(
      txidVersion,
      networkName,
      publicWalletAddress,
      railgunWalletID,
      wrappedERC20Amount,
      undefined, // no broadcaster fee
      true,      // sendWithPublicWallet
      undefined, // no min gas price
      gasDetails,
    );

    return { transaction: serializeTransaction(result.transaction) };
  });

  // -----------------------------------------------------------------------
  // Broadcaster-mediated unshield methods
  // -----------------------------------------------------------------------

  /**
   * Estimate gas for an unshield via broadcaster and compute the fee amount.
   *
   * params: {
   *   chainName: string,
   *   railgunWalletID: string,
   *   encryptionKey: string,
   *   publicWalletAddress: string,
   *   amount: string,          // in wei
   *   feePerUnitGas: string,   // from broadcaster
   * }
   */
  registerMethod("gasEstimateForBroadcasterUnshield", async (params) => {
    requireEngine();
    const { chainName, railgunWalletID, encryptionKey, publicWalletAddress, amount, feePerUnitGas } = params;
    const { networkName } = chainForName(chainName);
    const wrappedAddress = NETWORK_CONFIG[networkName].baseToken.wrappedAddress;
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const wrappedERC20Amount = {
      tokenAddress: wrappedAddress,
      amount: BigInt(amount),
    };

    const provider = getFallbackProviderForNetwork(networkName);
    const feeData = await provider.getFeeData();

    let originalGasDetails;
    if (feeData.maxFeePerGas != null) {
      originalGasDetails = {
        evmGasType: 2,
        gasEstimate: 0n,
        maxFeePerGas: feeData.maxFeePerGas,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ?? 1000000000n,
      };
    } else {
      originalGasDetails = {
        evmGasType: 1,
        gasEstimate: 0n,
        gasPrice: feeData.gasPrice ?? 1000000000n,
      };
    }

    const feeTokenDetails = {
      tokenAddress: wrappedAddress,
      feePerUnitGas: BigInt(feePerUnitGas),
    };

    const result = await gasEstimateForUnprovenUnshieldBaseToken(
      txidVersion,
      networkName,
      publicWalletAddress,
      railgunWalletID,
      encryptionKey,
      wrappedERC20Amount,
      originalGasDetails,
      feeTokenDetails,
      false, // sendWithPublicWallet — broadcaster pays gas
    );

    const gasEstimate = result.gasEstimate;
    const broadcasterFeeAmount = gasEstimate * BigInt(feePerUnitGas);
    const gasPrice = (feeData.gasPrice || feeData.maxFeePerGas || 0n);

    return {
      gasEstimate: gasEstimate.toString(),
      broadcasterFeeAmount: broadcasterFeeAmount.toString(),
      gasPrice: gasPrice.toString(),
    };
  });

  /**
   * Generate a ZK proof for unshield via broadcaster (includes broadcaster fee commitment).
   *
   * params: {
   *   chainName: string,
   *   railgunWalletID: string,
   *   encryptionKey: string,
   *   publicWalletAddress: string,
   *   amount: string,
   *   broadcasterFeeTokenAddress: string,
   *   broadcasterFeeAmount: string,
   *   broadcasterRailgunAddress: string,
   *   overallBatchMinGasPrice: string,
   * }
   */
  registerMethod("generateBroadcasterUnshieldProof", async (params) => {
    requireEngine();
    const {
      chainName, railgunWalletID, encryptionKey, publicWalletAddress, amount,
      broadcasterFeeTokenAddress, broadcasterFeeAmount, broadcasterRailgunAddress,
      overallBatchMinGasPrice,
    } = params;
    const { networkName } = chainForName(chainName);
    const wrappedAddress = NETWORK_CONFIG[networkName].baseToken.wrappedAddress;
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const wrappedERC20Amount = {
      tokenAddress: wrappedAddress,
      amount: BigInt(amount),
    };

    const broadcasterFeeERC20AmountRecipient = {
      tokenAddress: broadcasterFeeTokenAddress,
      amount: BigInt(broadcasterFeeAmount),
      recipientAddress: broadcasterRailgunAddress,
    };

    await generateUnshieldBaseTokenProof(
      txidVersion,
      networkName,
      publicWalletAddress,
      railgunWalletID,
      encryptionKey,
      wrappedERC20Amount,
      broadcasterFeeERC20AmountRecipient,
      false, // sendWithPublicWallet — broadcaster pays
      overallBatchMinGasPrice ? BigInt(overallBatchMinGasPrice) : undefined,
      (progress, status) => {
        sendEvent("proofProgress", { progress, status });
      },
    );

    return { proved: true };
  });

  /**
   * Populate a proved broadcaster unshield transaction.
   * Returns nullifiers and POIs needed for broadcaster submission.
   *
   * params: {
   *   chainName: string,
   *   railgunWalletID: string,
   *   publicWalletAddress: string,
   *   amount: string,
   *   broadcasterFeeTokenAddress: string,
   *   broadcasterFeeAmount: string,
   *   broadcasterRailgunAddress: string,
   *   overallBatchMinGasPrice: string,
   * }
   */
  registerMethod("populateBroadcasterUnshield", async (params) => {
    requireEngine();
    const {
      chainName, railgunWalletID, publicWalletAddress, amount,
      broadcasterFeeTokenAddress, broadcasterFeeAmount, broadcasterRailgunAddress,
      overallBatchMinGasPrice,
    } = params;
    const { networkName } = chainForName(chainName);
    const wrappedAddress = NETWORK_CONFIG[networkName].baseToken.wrappedAddress;
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const wrappedERC20Amount = {
      tokenAddress: wrappedAddress,
      amount: BigInt(amount),
    };

    const broadcasterFeeERC20AmountRecipient = {
      tokenAddress: broadcasterFeeTokenAddress,
      amount: BigInt(broadcasterFeeAmount),
      recipientAddress: broadcasterRailgunAddress,
    };

    const provider = getFallbackProviderForNetwork(networkName);
    const feeData = await provider.getFeeData();

    let gasDetails;
    if (feeData.maxFeePerGas != null) {
      gasDetails = {
        evmGasType: 2,
        gasEstimate: 1500000n,
        maxFeePerGas: feeData.maxFeePerGas,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ?? 1000000000n,
      };
    } else {
      gasDetails = {
        evmGasType: 1,
        gasEstimate: 1500000n,
        gasPrice: feeData.gasPrice ?? 1000000000n,
      };
    }

    const result = await populateProvedUnshieldBaseToken(
      txidVersion,
      networkName,
      publicWalletAddress,
      railgunWalletID,
      wrappedERC20Amount,
      broadcasterFeeERC20AmountRecipient,
      false, // sendWithPublicWallet
      overallBatchMinGasPrice ? BigInt(overallBatchMinGasPrice) : undefined,
      gasDetails,
    );

    return {
      transaction: serializeTransaction(result.transaction),
      nullifiers: result.nullifiers || [],
      preTransactionPOIsPerTxidLeafPerList: result.preTransactionPOIsPerTxidLeafPerList,
    };
  });
}

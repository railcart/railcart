import { registerMethod, sendEvent } from "./bridge.js";
import { CHAINS, chainForName } from "./chains.js";
import { WakuBroadcasterClient, BroadcasterTransaction } from "@railgun-community/waku-broadcaster-client-node";
import { TXIDVersion } from "@railgun-community/shared-models";

// Well-known trusted fee signer for production broadcasters
const TRUSTED_FEE_SIGNER =
  "0zk1qyzgh9ctuxm6d06gmax39xutjgrawdsljtv80lqnjtqp3exxayuf0rv7j6fe3z53laetcl9u3cma0q9k4npgy8c8ga4h6mx83v09m8ewctsekw4a079dcl5sw4k";

let currentChainName = null;

function serializeBroadcaster(b) {
  return {
    railgunAddress: b.railgunAddress,
    tokenAddress: b.tokenAddress,
    feePerUnitGas: b.tokenFee.feePerUnitGas,
    expiration: b.tokenFee.expiration,
    feesID: b.tokenFee.feesID,
    availableWallets: b.tokenFee.availableWallets,
    relayAdapt: b.tokenFee.relayAdapt,
    reliability: b.tokenFee.reliability,
  };
}

export function registerBroadcasterMethods() {
  registerMethod("startBroadcasterSearch", async (params) => {
    const { chainName } = params;
    const entry = chainForName(chainName);

    if (WakuBroadcasterClient.isStarted()) {
      if (currentChainName === chainName) {
        return { alreadyStarted: true };
      }
      await WakuBroadcasterClient.setChain(entry.chain);
      currentChainName = chainName;
      return { switched: true, chainName };
    }

    currentChainName = chainName;

    await WakuBroadcasterClient.start(
      entry.chain,
      { trustedFeeSigner: TRUSTED_FEE_SIGNER },
      (chain, status) => {
        sendEvent("broadcasterStatus", { chainId: chain.id, chainName, status });
      },
      {
        log: (msg) => console.log(`[broadcaster] ${msg}`),
        error: (err) => console.log(`[broadcaster error] ${err.message}`),
      }
    );

    return { started: true, chainName };
  });

  registerMethod("stopBroadcasterSearch", async () => {
    if (WakuBroadcasterClient.isStarted()) {
      await WakuBroadcasterClient.stop();
      currentChainName = null;
    }
    return { stopped: true };
  });

  registerMethod("getAllBroadcasters", async (params) => {
    if (!currentChainName) {
      throw new Error("Broadcaster search not started. Call startBroadcasterSearch first.");
    }
    const entry = chainForName(currentChainName);
    const useRelayAdapt = params.useRelayAdapt ?? true;
    const result = WakuBroadcasterClient.findAllBroadcastersForChain(entry.chain, useRelayAdapt);
    return { broadcasters: (result || []).map(serializeBroadcaster), chainName: currentChainName };
  });

  registerMethod("getBroadcastersForToken", async (params) => {
    if (!currentChainName) throw new Error("Broadcaster search not started.");
    const { tokenAddress } = params;
    if (!tokenAddress) throw new Error("tokenAddress is required");
    const entry = chainForName(currentChainName);
    const useRelayAdapt = params.useRelayAdapt ?? true;
    const result = WakuBroadcasterClient.findBroadcastersForToken(entry.chain, tokenAddress, useRelayAdapt);
    return { broadcasters: (result || []).map(serializeBroadcaster), chainName: currentChainName };
  });

  registerMethod("getBestBroadcaster", async (params) => {
    if (!currentChainName) throw new Error("Broadcaster search not started.");
    const { tokenAddress } = params;
    if (!tokenAddress) throw new Error("tokenAddress is required");
    const entry = chainForName(currentChainName);
    const useRelayAdapt = params.useRelayAdapt ?? true;
    const result = WakuBroadcasterClient.findBestBroadcaster(entry.chain, tokenAddress, useRelayAdapt);
    return { broadcaster: result ? serializeBroadcaster(result) : null };
  });

  registerMethod("getBroadcasterPeerStats", async () => {
    if (!WakuBroadcasterClient.isStarted()) return { started: false };
    return {
      started: true,
      meshPeerCount: WakuBroadcasterClient.getMeshPeerCount(),
      pubSubPeerCount: WakuBroadcasterClient.getPubSubPeerCount(),
      chainName: currentChainName,
    };
  });

  registerMethod("getSupportedChains", async () => {
    return {
      chains: Object.entries(CHAINS).map(([name, entry]) => ({
        name,
        chainId: entry.chain.id,
      })),
    };
  });

  /**
   * Submit a proved transaction to a broadcaster via Waku P2P.
   *
   * params: {
   *   chainName: string,
   *   to: string,
   *   data: string,
   *   broadcasterRailgunAddress: string,
   *   broadcasterFeesID: string,
   *   nullifiers: string[],
   *   overallBatchMinGasPrice: string,
   *   useRelayAdapt?: boolean,
   *   preTransactionPOIsPerTxidLeafPerList: object,
   * }
   */
  registerMethod("submitBroadcasterTransaction", async (params) => {
    const {
      chainName, to, data,
      broadcasterRailgunAddress, broadcasterFeesID,
      nullifiers, overallBatchMinGasPrice,
      useRelayAdapt,
      preTransactionPOIsPerTxidLeafPerList,
    } = params;

    if (!WakuBroadcasterClient.isStarted()) {
      throw new Error("Broadcaster search not started. Call startBroadcasterSearch first.");
    }

    const entry = chainForName(chainName);
    const txidVersion = TXIDVersion.V2_PoseidonMerkle;

    const broadcasterTx = await BroadcasterTransaction.create(
      txidVersion,
      to,
      data,
      broadcasterRailgunAddress,
      broadcasterFeesID,
      entry.chain,
      nullifiers,
      BigInt(overallBatchMinGasPrice),
      useRelayAdapt ?? true,
      preTransactionPOIsPerTxidLeafPerList,
    );

    const txHash = await broadcasterTx.send();
    return { txHash };
  });
}

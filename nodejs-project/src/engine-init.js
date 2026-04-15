import { registerMethod, sendEvent } from "./bridge.js";
import { chainForName } from "./chains.js";
import {
  startRailgunEngine,
  getProver,
  loadProvider,
  getFallbackProviderForNetwork,
  setOnUTXOMerkletreeScanCallback,
  setOnTXIDMerkletreeScanCallback,
  setOnWalletPOIProofProgressCallback,
} from "@railgun-community/wallet";
import * as snarkjs from "snarkjs";
import leveldown from "leveldown";
import fs from "fs/promises";
import path from "path";
import { loadRemoteConfig, getCachedRemoteConfig } from "./remote-config.js";

let engineInitialized = false;

// POI aggregator URLs resolved during initEngine (from remote config, with
// fallback). Exposed to Swift via the `getPOINodeURLs` bridge method so the
// native scanner doesn't need to duplicate the remote-config bootstrap.
let resolvedPOINodeURLs = [];

// Per-chain provider state for rotation/retry.
// candidates: all available providers (from remote config or custom)
// currentIndex: which candidate is currently loaded
const chainProviderState = {};

/**
 * Health-check a loaded provider by making a real RPC call.
 * Returns true if the provider responds within a timeout.
 */
async function healthCheckProvider(networkName) {
  const provider = getFallbackProviderForNetwork(networkName);
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error("Health check timed out")), 10000)
  );
  await Promise.race([provider.getBlockNumber(), timeout]);
}

/**
 * Try to rotate to the next available provider for a chain.
 * Returns true if a working provider was found, false if all exhausted.
 */
export async function tryRotateProvider(chainName) {
  const state = chainProviderState[chainName];
  if (!state || state.candidates.length <= 1) return false;

  const { networkName, chain } = chainForName(chainName);
  const startIndex = state.currentIndex;

  for (let i = 1; i < state.candidates.length; i++) {
    const idx = (startIndex + i) % state.candidates.length;
    const candidate = state.candidates[idx];
    try {
      const providerConfig = { chainId: chain.id, providers: [candidate] };
      await loadProvider(providerConfig, networkName);
      await healthCheckProvider(networkName);
      state.currentIndex = idx;
      process.stderr.write(
        `[sync] Rotated provider for ${chainName}: ${candidate.provider}\n`
      );
      sendEvent("providerRotated", {
        chainName,
        providerUrl: candidate.provider,
      });
      return true;
    } catch (err) {
      process.stderr.write(
        `[sync] Rotation candidate ${candidate.provider} failed for ${chainName}: ${err?.message || err}\n`
      );
    }
  }
  process.stderr.write(
    `[sync] All ${state.candidates.length} providers exhausted for ${chainName}\n`
  );
  return false;
}

function getDataDir() {
  const home = process.env.HOME || process.env.USERPROFILE || "/tmp";
  return path.join(home, ".railcart");
}

function createArtifactStore(baseDir) {
  const artifactsDir = path.join(baseDir, "artifacts");

  return {
    async get(artifactPath) {
      const fullPath = path.join(artifactsDir, artifactPath);
      try {
        return await fs.readFile(fullPath);
      } catch {
        return null;
      }
    },
    async store(dir, artifactPath, data) {
      const fullDir = path.join(artifactsDir, dir);
      await fs.mkdir(fullDir, { recursive: true });
      const fullPath = path.join(artifactsDir, artifactPath);
      await fs.writeFile(fullPath, data);
    },
    async exists(artifactPath) {
      const fullPath = path.join(artifactsDir, artifactPath);
      try {
        await fs.access(fullPath);
        return true;
      } catch {
        return false;
      }
    },
  };
}

export function isEngineInitialized() {
  return engineInitialized;
}

/**
 * Get the current RPC provider URL for a chain (for logging).
 */
export function currentProviderUrl(chainName) {
  const state = chainProviderState[chainName];
  if (!state) return "(no provider)";
  const candidate = state.candidates[state.currentIndex];
  return candidate?.provider ?? "(unknown)";
}

export function registerEngineInitMethods() {
  /**
   * Initialize the RAILGUN engine.
   *
   * params: {
   *   dataDir?: string  (defaults to ~/.railcart)
   *   ethereumRpcUrl?: string  (custom Ethereum RPC for remote config fetch)
   * }
   */
  registerMethod("initEngine", async (params) => {
    if (engineInitialized) {
      return { alreadyInitialized: true };
    }

    const dataDir = params.dataDir || getDataDir();
    const dbDir = path.join(dataDir, "db");

    await fs.mkdir(dbDir, { recursive: true });

    const db = leveldown(dbDir);
    const artifactStore = createArtifactStore(dataDir);

    // Fetch the official RAILGUN remote config from the on-chain contract.
    // This gives us community-maintained POI aggregator URLs (and version
    // pins, etc.) without hardcoding values that may rotate. Falls back to
    // the public test aggregator if the contract call fails.
    // Uses the custom Ethereum RPC if provided, otherwise the Flashbots
    // bootstrap RPC.
    const FALLBACK_POI_URL = "https://ppoi-agg.horsewithsixlegs.xyz";
    let poiNodeURLs = [FALLBACK_POI_URL];
    try {
      const remoteConfig = await loadRemoteConfig(params.ethereumRpcUrl || undefined);
      if (Array.isArray(remoteConfig.publicPoiAggregatorUrls) && remoteConfig.publicPoiAggregatorUrls.length > 0) {
        poiNodeURLs = [...remoteConfig.publicPoiAggregatorUrls, FALLBACK_POI_URL];
      }
      process.stderr.write(`[sync] Loaded remote config (${poiNodeURLs.length} POI aggregator URLs)\n`);
    } catch (err) {
      process.stderr.write(`[sync] Remote config fetch failed, using fallback POI URL: ${err?.message || err}\n`);
    }

    resolvedPOINodeURLs = poiNodeURLs;

    await startRailgunEngine(
      "rgwallet",       // walletSource (max 16 chars, lowercase)
      db,
      false,            // shouldDebug
      artifactStore,
      false,            // useNativeArtifacts (false for Node.js)
      false,            // skipMerkletreeScans — we need scanning for balances
      poiNodeURLs,
    );

    // Configure the groth16 prover for ZK proof generation
    getProver().setSnarkJSGroth16(snarkjs.groth16);

    // Register scan callbacks after engine is initialized
    setOnUTXOMerkletreeScanCallback(({ scanStatus, chain, progress }) => {
      if (scanStatus === "Started") {
        process.stderr.write(`[sync] UTXO merkletree scan started (chain ${chain.id})\n`);
      } else if (scanStatus === "Complete") {
        process.stderr.write(`[sync] UTXO merkletree scan complete (chain ${chain.id})\n`);
      } else if (scanStatus === "Updated" && progress !== undefined) {
        // Log every 10% to avoid flooding
        const pct = Math.round(progress * 100);
        if (pct % 10 === 0) {
          process.stderr.write(`[sync] UTXO scan progress: ${pct}% (chain ${chain.id})\n`);
        }
      }
      sendEvent("scanProgress", {
        type: "utxo",
        scanStatus,
        chainId: chain.id,
        progress,
      });
    });

    // Forward POI proof generation progress to Swift. Fires during
    // `generatePOIProofs` as legacy/transact/unshield proofs are built and
    // submitted to the POI aggregator.
    setOnWalletPOIProofProgressCallback((poiProofEvent) => {
      sendEvent("poiProofProgress", poiProofEvent);
    });

    setOnTXIDMerkletreeScanCallback(({ scanStatus, chain, progress }) => {
      if (scanStatus === "Started") {
        process.stderr.write(`[sync] TXID merkletree scan started (chain ${chain.id})\n`);
      } else if (scanStatus === "Complete") {
        process.stderr.write(`[sync] TXID merkletree scan complete (chain ${chain.id})\n`);
      }
      sendEvent("scanProgress", {
        type: "txid",
        scanStatus,
        chainId: chain.id,
        progress,
      });
    });

    engineInitialized = true;
    process.stderr.write(`[sync] Engine initialized, data dir: ${dataDir}\n`);
    sendEvent("engineInitialized", {});
    return { initialized: true, dataDir };
  });

  /**
   * Return the POI aggregator URLs resolved at engine-init time.
   * Used by the native scanner to query the POI node directly.
   */
  registerMethod("getPOINodeURLs", async () => {
    if (!engineInitialized) {
      throw new Error("Engine not initialized. Call initEngine first.");
    }
    return { urls: resolvedPOINodeURLs };
  });

  /**
   * Load an RPC provider for a chain.
   *
   * params: {
   *   chainName: string,
   *   providerUrl: string,
   * }
   */
  registerMethod("loadChainProvider", async (params) => {
    if (!engineInitialized) {
      throw new Error("Engine not initialized. Call initEngine first.");
    }

    const { chainName, providerUrl } = params;
    if (!providerUrl) {
      throw new Error("providerUrl is required");
    }

    const { networkName, chain } = chainForName(chainName);

    const candidate = { provider: providerUrl, priority: 1, weight: 2 };
    const providerConfig = {
      chainId: chain.id,
      providers: [candidate],
    };

    await loadProvider(providerConfig, networkName);

    // Verify the provider actually responds to RPC calls.
    try {
      await healthCheckProvider(networkName);
    } catch (err) {
      throw new Error(
        `Provider ${providerUrl} loaded but failed health check: ${err?.message || err}`
      );
    }

    // Store as the sole candidate (custom URL overrides remote config list).
    chainProviderState[chainName] = {
      candidates: [candidate],
      currentIndex: 0,
      networkName,
    };

    process.stderr.write(`[sync] Loaded provider for ${chainName} (${networkName})\n`);
    return { chainName, loaded: true };
  });

  /**
   * Load an RPC provider for a chain using the URL list from the cached
   * remote config. Throws if the remote config hasn't loaded or doesn't
   * contain an entry for this chain.
   *
   * params: { chainName: string }
   */
  registerMethod("loadChainProviderFromRemoteConfig", async (params) => {
    if (!engineInitialized) {
      throw new Error("Engine not initialized. Call initEngine first.");
    }
    const { chainName } = params;
    const remoteConfig = getCachedRemoteConfig();
    if (!remoteConfig || !remoteConfig.network) {
      throw new Error("Remote config not available");
    }

    const { networkName, chain } = chainForName(chainName);
    const entry = remoteConfig.network[chain.id] || remoteConfig.network[String(chain.id)];
    if (!entry || !Array.isArray(entry.providers) || entry.providers.length === 0) {
      throw new Error(`Remote config has no providers for chain ${chainName} (id ${chain.id})`);
    }

    // Normalize each entry: strings become a default ProviderJson, objects pass through.
    const allProviders = entry.providers
      .map((p) => {
        if (typeof p === "string") {
          return { provider: p, priority: 1, weight: 2 };
        }
        if (p && typeof p === "object" && typeof p.provider === "string") {
          return { provider: p.provider, priority: 1, weight: 2 };
        }
        return null;
      })
      .filter(Boolean);

    if (allProviders.length === 0) {
      throw new Error(`Remote config providers for ${chainName} were unparseable`);
    }

    // Shuffle and try each provider individually until one passes a real
    // health check (getBlockNumber). Retry once after a delay — the SDK's
    // loadProvider network detection is flaky on public RPCs.
    const shuffled = allProviders.sort(() => Math.random() - 0.5);
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        process.stderr.write(`[sync] Retrying provider load for ${chainName} after 3s\n`);
        await new Promise((r) => setTimeout(r, 3000));
      }
      for (let i = 0; i < shuffled.length; i++) {
        const candidate = shuffled[i];
        try {
          const providerConfig = { chainId: chain.id, providers: [candidate] };
          await loadProvider(providerConfig, networkName);
          await healthCheckProvider(networkName);

          chainProviderState[chainName] = {
            candidates: shuffled,
            currentIndex: i,
            networkName,
          };

          process.stderr.write(`[sync] Loaded provider from remote config for ${chainName} (${networkName}): ${candidate.provider}\n`);
          return { chainName, loaded: true, providerCount: 1, providerUrls: [candidate.provider] };
        } catch (err) {
          process.stderr.write(`[sync] Provider ${candidate.provider} failed for ${chainName}: ${err?.message || err}\n`);
        }
      }
    }
    throw new Error(`All ${shuffled.length} remote config providers failed for ${chainName}`);
  });

  /**
   * Rotate to the next available RPC provider for a chain.
   * Called from Swift when a direct RPC call (e.g. signAndSend) fails.
   *
   * params: { chainName: string }
   */
  registerMethod("rotateChainProvider", async (params) => {
    if (!engineInitialized) {
      throw new Error("Engine not initialized. Call initEngine first.");
    }
    const { chainName } = params;
    const rotated = await tryRotateProvider(chainName);
    if (!rotated) {
      throw new Error(`No alternative providers available for ${chainName}`);
    }
    const state = chainProviderState[chainName];
    const url = state.candidates[state.currentIndex].provider;
    return { chainName, rotated: true, providerUrl: url };
  });

}

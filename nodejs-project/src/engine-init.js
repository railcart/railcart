import { registerMethod, sendEvent } from "./bridge.js";
import { chainForName } from "./chains.js";
import {
  startRailgunEngine,
  getProver,
  loadProvider,
  setOnUTXOMerkletreeScanCallback,
  setOnTXIDMerkletreeScanCallback,
} from "@railgun-community/wallet";
import * as snarkjs from "snarkjs";
import leveldown from "leveldown";
import fs from "fs/promises";
import path from "path";
import { loadRemoteConfig, getCachedRemoteConfig } from "./remote-config.js";

let engineInitialized = false;

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

    const providerConfig = {
      chainId: chain.id,
      providers: [
        {
          provider: providerUrl,
          priority: 1,
          weight: 2,
        },
      ],
    };

    await loadProvider(providerConfig, networkName);
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

    // Shuffle and try each provider individually until one loads successfully.
    // Avoids FallbackProvider quorum issues while still providing resilience.
    const shuffled = allProviders.sort(() => Math.random() - 0.5);
    for (const candidate of shuffled) {
      try {
        const providerConfig = { chainId: chain.id, providers: [candidate] };
        await loadProvider(providerConfig, networkName);
        process.stderr.write(`[sync] Loaded provider from remote config for ${chainName} (${networkName}): ${candidate.provider}\n`);
        return { chainName, loaded: true, providerCount: 1, providerUrls: [candidate.provider] };
      } catch (err) {
        process.stderr.write(`[sync] Provider ${candidate.provider} failed for ${chainName}: ${err?.message || err}\n`);
      }
    }
    throw new Error(`All ${shuffled.length} remote config providers failed for ${chainName}`);
  });
}

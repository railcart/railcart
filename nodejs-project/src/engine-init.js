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

    const poiNodeURLs = ["https://ppoi-agg.horsewithsixlegs.xyz"];

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
}

import { Contract, JsonRpcProvider } from "ethers";
import { registerMethod } from "./bridge.js";

// Official RAILGUN remote-config contract on Ethereum mainnet.
// Returns a JSON string containing community-maintained config (POI aggregator
// URLs, version pins, Waku bootstrap peers, etc.) so wallets don't need to
// hardcode values that may rotate over time.
const REMOTE_CONFIG_CONTRACT = "0x5e982525d50046A813DBf55Ae72a3E00e99fbC94";
const REMOTE_CONFIG_ABI = [
  "function getConfig() public view returns (string memory str)",
];

// Bootstrap RPC used solely for the one-shot remote-config contract call at
// startup. Flashbots is privacy-respecting (no logging policy) and free.
// After this call, the engine switches to providers from the remote config
// itself for all subsequent chain access.
const BOOTSTRAP_RPC = "https://rpc.flashbots.net";

let cachedConfig = null;

export function getCachedRemoteConfig() {
  return cachedConfig;
}

/**
 * Fetch and cache the RAILGUN remote config from the on-chain contract.
 * Throws on failure — caller decides whether to fall back.
 */
export async function loadRemoteConfig(rpcUrl = BOOTSTRAP_RPC) {
  const provider = new JsonRpcProvider(rpcUrl);
  const contract = new Contract(REMOTE_CONFIG_CONTRACT, REMOTE_CONFIG_ABI, provider);
  const raw = await contract.getConfig();
  const parsed = JSON.parse(raw);
  cachedConfig = parsed;
  return parsed;
}

export function registerRemoteConfigMethods() {
  /**
   * Return the cached remote config (or null if it hasn't loaded yet).
   */
  registerMethod("getRemoteConfig", async () => {
    return { config: cachedConfig };
  });
}

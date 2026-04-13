import { startBridge, registerMethod, sendEvent } from "./bridge.js";
import { registerEngineInitMethods } from "./engine-init.js";
import { registerBroadcasterMethods } from "./broadcaster.js";
import { registerWalletMethods } from "./wallet.js";
import { registerRemoteConfigMethods } from "./remote-config.js";
import { registerNativeProofMethods } from "./native-proof.js";

// Prevent unhandled errors from crashing the process
process.on("unhandledRejection", (err) => {
  process.stderr.write(`[unhandledRejection] ${err?.stack || err}\n`);
});

// Redirect console.log to stderr so it doesn't interfere with the bridge protocol
console.log = (...args) => {
  process.stderr.write(args.join(" ") + "\n");
};

// Register built-in methods
registerMethod("ping", async () => ({ pong: true, timestamp: Date.now() }));

registerMethod("getStatus", async () => ({
  nodeVersion: process.version,
  uptime: process.uptime(),
  memoryUsage: process.memoryUsage(),
}));

// Register domain methods
registerEngineInitMethods();
registerBroadcasterMethods();
registerWalletMethods();
registerRemoteConfigMethods();
registerNativeProofMethods();

// Start the bridge
startBridge();

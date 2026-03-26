/**
 * Bridge protocol: newline-delimited JSON over stdin/stdout.
 *
 * Request (Swift → Node):  { "id": "uuid", "method": "string", "params": {} }
 * Response (Node → Swift): { "id": "uuid", "result": {} } or { "id": "uuid", "error": { "code": number, "message": "string" } }
 * Event (Node → Swift):    { "event": "string", "data": {} }
 */

const handlers = new Map();

/**
 * Register a method handler.
 * @param {string} method
 * @param {(params: any) => Promise<any>} handler
 */
export function registerMethod(method, handler) {
  handlers.set(method, handler);
}

/**
 * Send an event to Swift (no response expected).
 */
export function sendEvent(event, data) {
  const msg = JSON.stringify({ event, data });
  process.stdout.write(msg + "\n");
}

/**
 * Send a response to a request.
 */
function sendResponse(id, result) {
  const msg = JSON.stringify({ id, result });
  process.stdout.write(msg + "\n");
}

/**
 * Send an error response to a request.
 */
function sendError(id, code, message) {
  const msg = JSON.stringify({ id, error: { code, message } });
  process.stdout.write(msg + "\n");
}

/**
 * Process a single incoming message line.
 */
async function handleMessage(line) {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    // Malformed JSON — log to stderr (which Swift can capture) and skip
    process.stderr.write(`[bridge] malformed JSON: ${line}\n`);
    return;
  }

  const { id, method, params } = request;
  if (!id || !method) {
    process.stderr.write(`[bridge] missing id or method: ${line}\n`);
    return;
  }

  const handler = handlers.get(method);
  if (!handler) {
    sendError(id, -32601, `Unknown method: ${method}`);
    return;
  }

  try {
    const result = await handler(params ?? {});
    sendResponse(id, result ?? null);
  } catch (err) {
    sendError(id, -32000, err.message ?? String(err));
  }
}

/**
 * Start listening on stdin for newline-delimited JSON messages.
 */
export function startBridge() {
  let buffer = "";

  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    // Keep the last (potentially incomplete) chunk in the buffer
    buffer = lines.pop();
    for (const line of lines) {
      if (line.trim()) {
        handleMessage(line);
      }
    }
  });

  process.stdin.on("end", () => {
    // Parent process closed stdin — exit cleanly
    process.exit(0);
  });

  sendEvent("ready", { version: "0.1.0" });
}

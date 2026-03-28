import { describe, it, mock, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { serializeTransaction } from "./wallet.js";

// ---------------------------------------------------------------------------
// serializeTransaction — the contract between the SDK and Swift's TransactionData
// Swift expects: { to: String, data: String, value: String, gasLimit: String?, chainId: String? }
// ---------------------------------------------------------------------------

describe("serializeTransaction", () => {
  it("serializes a typical SDK transaction", () => {
    const tx = {
      to: "0xabc123",
      data: "0xdeadbeef",
      value: 1000000000000000000n, // 1 ETH in wei
      gasLimit: 200000n,
      chainId: 1n,
    };

    const result = serializeTransaction(tx);

    assert.deepStrictEqual(result, {
      to: "0xabc123",
      data: "0xdeadbeef",
      value: "1000000000000000000",
      gasLimit: "200000",
      chainId: "1",
    });
  });

  it("defaults value to '0' when undefined", () => {
    const tx = { to: "0xabc", data: "0x00" };
    const result = serializeTransaction(tx);

    assert.equal(result.value, "0");
  });

  it("defaults value to '0' when null", () => {
    const tx = { to: "0xabc", data: "0x00", value: null };
    const result = serializeTransaction(tx);

    assert.equal(result.value, "0");
  });

  it("passes through string values without conversion", () => {
    const tx = {
      to: "0xabc",
      data: "0x00",
      value: "500",
      gasLimit: "21000",
      chainId: "11155111",
    };
    const result = serializeTransaction(tx);

    assert.equal(result.value, "500");
    assert.equal(result.gasLimit, "21000");
    assert.equal(result.chainId, "11155111");
  });

  it("leaves gasLimit and chainId undefined when not provided", () => {
    const tx = { to: "0xabc", data: "0x00", value: 0n };
    const result = serializeTransaction(tx);

    assert.equal(result.gasLimit, undefined);
    assert.equal(result.chainId, undefined);
  });

  it("preserves to and data exactly as-is", () => {
    const longData = "0x" + "ab".repeat(1000);
    const tx = { to: "0x1234567890abcdef", data: longData, value: 0n };
    const result = serializeTransaction(tx);

    assert.equal(result.to, "0x1234567890abcdef");
    assert.equal(result.data, longData);
  });

  it("produces a JSON-serializable result (no BigInt)", () => {
    const tx = {
      to: "0xabc",
      data: "0x00",
      value: 999999999999999999999n,
      gasLimit: 30000000n,
      chainId: 42161n,
    };
    const result = serializeTransaction(tx);

    // JSON.stringify throws on BigInt — this must not throw
    const json = JSON.stringify(result);
    assert.ok(json);

    // Round-trip should preserve all values
    const parsed = JSON.parse(json);
    assert.equal(parsed.value, "999999999999999999999");
    assert.equal(parsed.gasLimit, "30000000");
    assert.equal(parsed.chainId, "42161");
  });
});

// ---------------------------------------------------------------------------
// Shield response shape — validate the structure Swift decodes as
// ShieldTransactionResponse { transaction: TransactionData }
// ---------------------------------------------------------------------------

describe("shield response shape", () => {
  it("matches Swift's ShieldTransactionResponse / TransactionData", () => {
    // Simulate what shieldBaseToken returns after serializeTransaction
    const sdkResult = {
      transaction: {
        to: "0x4025ee6512DBbda97049Bcf5AA5D38C54aF6bE8a",
        data: "0x12345678",
        value: 100000000000000000n,
        gasLimit: 1500000n,
        chainId: 11155111n,
      },
    };

    const response = {
      transaction: serializeTransaction(sdkResult.transaction),
    };

    // Verify the top-level key exists
    assert.ok(response.transaction, "response must have 'transaction' key");

    // Verify all required fields for Swift's TransactionData
    const tx = response.transaction;
    assert.equal(typeof tx.to, "string", "to must be a string");
    assert.equal(typeof tx.data, "string", "data must be a string");
    assert.equal(typeof tx.value, "string", "value must be a string");

    // Optional fields must be string or undefined (not number, not BigInt)
    if (tx.gasLimit !== undefined) {
      assert.equal(typeof tx.gasLimit, "string", "gasLimit must be string if present");
    }
    if (tx.chainId !== undefined) {
      assert.equal(typeof tx.chainId, "string", "chainId must be string if present");
    }

    // Must be valid JSON (no BigInt)
    assert.doesNotThrow(() => JSON.stringify(response));
  });

  it("value is never missing from the response", () => {
    // Even if the SDK returns no value field, we should get "0"
    const sdkResult = {
      transaction: { to: "0xabc", data: "0x00" },
    };

    const response = {
      transaction: serializeTransaction(sdkResult.transaction),
    };

    assert.equal(response.transaction.value, "0");
  });
});

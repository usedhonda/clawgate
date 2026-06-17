import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

import { clawgateHealth, clawgateSend } from "../client.js";

const originalFetch = globalThis.fetch;
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;

let timeoutCalls = [];
let clearCalls = [];

describe("clawgate HTTP client timeouts", () => {
  beforeEach(() => {
    timeoutCalls = [];
    clearCalls = [];
    globalThis.fetch = async () => ({ json: async () => ({ ok: true }) });
    globalThis.setTimeout = (fn, ms, ...args) => {
      timeoutCalls.push(ms);
      return originalSetTimeout(fn, 1_000_000, ...args);
    };
    globalThis.clearTimeout = (timer) => {
      clearCalls.push(timer);
      return originalClearTimeout(timer);
    };
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  });

  it("keeps health probes on the default 10s timeout", async () => {
    await clawgateHealth("http://127.0.0.1:8765");
    assert.deepEqual(timeoutCalls, [10_000]);
    assert.equal(clearCalls.length, 1);
  });

  it("allows LINE send requests 30s for AX and event-loop jitter", async () => {
    await clawgateSend("http://127.0.0.1:8765", "Test User", "test", "trace-1");
    assert.deepEqual(timeoutCalls, [30_000]);
    assert.equal(clearCalls.length, 1);
  });
});

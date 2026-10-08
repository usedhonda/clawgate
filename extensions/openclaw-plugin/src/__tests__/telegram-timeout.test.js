import { it } from "node:test";
import assert from "node:assert/strict";
import { telegramSend } from "../client.js";

it("aborts a stalled Telegram send and returns failure within the send budget", async () => {
  const saved = { fetch: globalThis.fetch, setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
  const budgets = [];
  let cleared = 0;
  try {
    globalThis.setTimeout = (fn, ms) => {
      budgets.push(ms);
      return saved.setTimeout(fn, 1);
    };
    globalThis.clearTimeout = (timer) => { cleared++; saved.clearTimeout(timer); };
    globalThis.fetch = async (_url, { signal }) => new Promise((_resolve, reject) => {
      signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
    });
    const result = await Promise.race([
      telegramSend("test-token", "test-chat", "offline test"),
      new Promise((resolve) => saved.setTimeout(() => resolve("still pending"), 50)),
    ]);
    assert.notEqual(result, "still pending", "a stalled notification must settle");
    assert.equal(result.ok, false);
    assert.deepEqual(budgets, [30_000]);
    assert.equal(cleared, 1);
  } finally {
    Object.assign(globalThis, saved);
  }
});

it("keeps the timeout active while reading a stalled response body", async () => {
  const savedFetch = globalThis.fetch;
  const savedTimer = globalThis.setTimeout;
  try {
    globalThis.setTimeout = (fn) => savedTimer(fn, 1);
    globalThis.fetch = async (_url, { signal }) => ({
      json: () => new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(new Error("aborted body")), { once: true });
      }),
    });
    const result = await telegramSend("test-token", "test-chat", "offline test");
    assert.equal(result.ok, false);
  } finally {
    globalThis.fetch = savedFetch;
    globalThis.setTimeout = savedTimer;
  }
});

it("preserves successful Telegram acknowledgements and clears the timer", async () => {
  const savedFetch = globalThis.fetch;
  const savedClear = globalThis.clearTimeout;
  let cleared = 0;
  try {
    globalThis.fetch = async () => ({ json: async () => ({ ok: true, result: { message_id: 42 } }) });
    globalThis.clearTimeout = (timer) => { cleared++; savedClear(timer); };
    const result = await telegramSend("test-token", "test-chat", "offline test");
    assert.equal(result.ok, true);
    assert.equal(result.result.message_id, "42");
    assert.equal(cleared, 1);
  } finally {
    globalThis.fetch = savedFetch;
    globalThis.clearTimeout = savedClear;
  }
});

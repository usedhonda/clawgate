import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, copyFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

test("client-only legacy poll works without verifier; protected poll cannot downgrade", async () => {
  const dir = await mkdtemp(join(tmpdir(), "clawgate-client-only-"));
  const originalFetch = globalThis.fetch;
  let requests = 0;
  try {
    await copyFile(new URL("../client.js", import.meta.url), join(dir, "client.mjs"));
    globalThis.fetch = async () => {
      requests++;
      return { json: async () => ({ ok: true, events: [], next_cursor: 4 }) };
    };
    const { clawgatePoll } = await import(pathToFileURL(join(dir, "client.mjs")));
    assert.deepEqual(await clawgatePoll("http://bridge.invalid", 4),
      { ok: true, events: [], next_cursor: 4 });
    await assert.rejects(clawgatePoll("http://bridge.invalid", 4,
      { issuerPublicKeyHex: "0".repeat(64) }), { code: "ERR_MODULE_NOT_FOUND" });
    assert.equal(requests, 1);
  } finally {
    globalThis.fetch = originalFetch;
    await rm(dir, { recursive: true, force: true });
  }
});

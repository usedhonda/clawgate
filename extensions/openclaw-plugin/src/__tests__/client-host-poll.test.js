import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { clawgatePoll } from "../client.js";
import { pollSigningBytes } from "../bridge-admission.js";

test("host poll request is preserved, URI-bound and never downgraded", async () => {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  const issuerPublicKeyHex = raw.toString("hex");
  const keyId = createHash("sha256").update(raw).digest("hex");
  const pollRequest = Object.freeze({ uri: "/v1/poll?since=4", challenge: "a".repeat(64) });
  const body = Buffer.from(JSON.stringify({ ok: true, events: [], next_cursor: 4 }));
  const originalFetch = globalThis.fetch;
  let requests = 0;
  let changeSignature = false;
  try {
    globalThis.fetch = async (url, options) => {
      requests++;
      assert.equal(new URL(url).pathname + new URL(url).search, pollRequest.uri);
      assert.equal(options.headers["X-ClawGate-Challenge"], pollRequest.challenge);
      assert.equal(options.redirect, "error");
      const signature = sign(null, pollSigningBytes({ method: "GET", uri: pollRequest.uri,
        challenge: changeSignature ? "b".repeat(64) : pollRequest.challenge,
        status: 200, keyId, body }), privateKey).toString("base64");
      return new Response(body, { status: 200, headers: {
        "X-ClawGate-Issuer-Version": "1", "X-ClawGate-Issuer-Key-Id": keyId,
        "X-ClawGate-Issuer-Signature": signature,
      } });
    };
    await assert.rejects(clawgatePoll("http://bridge.invalid", 4, { pollRequest }),
      /bridge_poll_invalid_host_request/);
    await assert.rejects(clawgatePoll("http://bridge.invalid", 5, { issuerPublicKeyHex, pollRequest }),
      /bridge_poll_invalid_host_request/);
    assert.equal(requests, 0);
    const response = await clawgatePoll("http://bridge.invalid", 4, { issuerPublicKeyHex, pollRequest });
    assert.equal(response.next_cursor, 4);
    assert.equal(Object.isFrozen(response), true);
    changeSignature = true;
    await assert.rejects(clawgatePoll("http://bridge.invalid", 4, { issuerPublicKeyHex, pollRequest }),
      /bridge_poll_signature_rejected/);
    assert.equal(requests, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

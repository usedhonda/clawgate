import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { pollSigningBytes, verifyPollResponse, verifiedBridgePollEvidence } from "../bridge-admission.js";
import { prepareBridgeAdmissionPolls } from "../bridge-admission-selection.js";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const rawKey = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
const publicKeyHex = rawKey.toString("hex");
const keyId = createHash("sha256").update(rawKey).digest("hex");
const status = 200;

function verifyPoll(uri, challenge, events, nextCursor) {
  const body = Buffer.from(JSON.stringify({ ok: true, events, next_cursor: nextCursor }));
  const signature = sign(null, pollSigningBytes({ method: "GET", uri, challenge, status, keyId, body }), privateKey);
  return verifyPollResponse({
    publicKeyHex,
    challenge,
    uri,
    status,
    headers: new Headers({
      "X-ClawGate-Issuer-Version": "1",
      "X-ClawGate-Issuer-Key-Id": keyId,
      "X-ClawGate-Issuer-Signature": signature.toString("base64"),
    }),
    body,
  });
}

test("prepares only ordered original verified poll groups", () => {
  const firstPoll = verifyPoll("/v1/poll?since=0", "a".repeat(64), [
    { id: 1, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z" },
    { id: 2, type: "inbound_message", adapter: "debug", observedAt: "2026-01-01T00:00:01Z" },
  ], 2);
  const secondPoll = verifyPoll("/v1/poll?since=2", "b".repeat(64), [
    { id: 3, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:02Z" },
  ], 3);
  const first = firstPoll.events[0];
  const second = firstPoll.events[1];
  const third = secondPoll.events[0];

  const prepared = prepareBridgeAdmissionPolls([first, second, third]);
  assert.equal(prepared.length, 2);
  assert.strictEqual(prepared[0].envelope, verifiedBridgePollEvidence(first).envelope);
  assert.deepEqual(prepared[0].eventIndexes, [0, 1]);
  assert.strictEqual(prepared[1].envelope, verifiedBridgePollEvidence(third).envelope);
  assert.deepEqual(prepared[1].eventIndexes, [0]);
  assert.ok(Object.isFrozen(prepared));
  assert.ok(Object.isFrozen(prepared[0]));
  assert.ok(Object.isFrozen(prepared[0].eventIndexes));

  assert.equal(prepareBridgeAdmissionPolls([]), null);
  assert.equal(prepareBridgeAdmissionPolls([structuredClone(first)]), null);
  assert.equal(prepareBridgeAdmissionPolls([first, { id: 99 }]), null);
  assert.equal(prepareBridgeAdmissionPolls([second, first]), null);
  assert.equal(prepareBridgeAdmissionPolls([first, first]), null);
  assert.equal(prepareBridgeAdmissionPolls([first, second, third, first]), null);
});

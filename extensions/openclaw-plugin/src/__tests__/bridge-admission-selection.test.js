import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { pollSigningBytes, verifyPollResponse, verifiedBridgePollEvidence } from "../bridge-admission.js";
import { prepareBridgeAdmissionPolls, createHostBridgePollSession } from "../bridge-admission-selection.js";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const rawKey = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
const publicKeyHex = rawKey.toString("hex");
const keyId = createHash("sha256").update(rawKey).digest("hex");
const status = 200;

test("one host-prepared poll binds separate original groups without reconsumption or fallback", async () => {
  const challenge = "c".repeat(64);
  const uri = "/v1/poll?since=4";
  const capability = Object.freeze({ kind: "fixture-poll" });
  const dispatchCapability = Object.freeze({ kind: "fixture-dispatch" });
  let preparedCount = 0;
  const selections = [];
  const bound = [];
  let unknown = false;
  const runtime = {
    issuePollRequest: async ({ accountId, since }) => {
      assert.equal(since, 4);
      return { status: "issued", request: { accountId, uri, challenge } };
    },
    preparePoll: async ({ accountId, envelope }) => {
      assert.equal(accountId, "fixture-account");
      assert.equal(envelope.challenge, challenge);
      preparedCount++;
      return { status: "prepared", capability };
    },
    receivePrepared: async ({ polls }) => {
      assert.equal(polls.length, 1);
      assert.strictEqual(polls[0].capability, capability);
      selections.push(polls[0].eventIndexes);
      return unknown ? { status: "unknown" } : { status: "accepted", capability: dispatchCapability };
    },
    bindContext: async (context, received) => {
      assert.strictEqual(received, dispatchCapability);
      bound.push(context);
      return true;
    },
  };
  const session = createHostBridgePollSession({ runtime, accountId: "fixture-account",
    issuerPublicKeyHex: publicKeyHex,
    poll: async (_apiUrl, _since, options) => {
      assert.equal(options.issuerPublicKeyHex, publicKeyHex);
      assert.equal(options.pollRequest.challenge, challenge);
      return verifyPoll(uri, challenge, [
        { id: 5, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z" },
        { id: 6, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:01Z" },
      ], 6);
    } });
  const response = await session.poll("http://bridge.invalid", 4);
  const firstContext = {};
  const secondContext = {};
  await session.bind(firstContext, [response.events[0]]);
  await session.bind(secondContext, [response.events[1]]);
  assert.equal(preparedCount, 1);
  assert.deepEqual(selections, [[0], [1]]);
  assert.deepEqual(bound, [firstContext, secondContext]);
  await assert.rejects(session.bind({}, [structuredClone(response.events[0])]), /original_group_missing/);
  unknown = true;
  await assert.rejects(session.bind({}, [response.events[1]]), /group_not_bound/);
  assert.equal(bound.length, 2);
  assert.equal(preparedCount, 1);
});

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

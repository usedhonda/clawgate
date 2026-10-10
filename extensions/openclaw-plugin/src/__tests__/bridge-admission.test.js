import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { pollSigningBytes, verifyPollResponse, verifiedBridgeAdmission, verifiedBridgePollEvidence } from "../bridge-admission.js";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const raw = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
const pin = raw.toString("hex");
const keyId = createHash("sha256").update(raw).digest("hex");
const challenge = "a".repeat(64), uri = "/v1/poll?since=4", status = 200;
const event = { id: 5, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z", payload: { text: "fixture" },
  admission: { admission_id: "00000000-0000-4000-8000-000000000001", generation: "00000000-0000-4000-8000-000000000002",
    event_id: 5, event_type: "inbound_message", adapter: "line", observed_at: "2026-01-01T00:00:00Z",
    provenance: "watcher_accepted", issuer_key_id: keyId } };
function envelope(events = [event]) {
  const body = Buffer.from(JSON.stringify({ ok: true, events, next_cursor: 5 }));
  const headers = new Headers({ "X-ClawGate-Issuer-Version": "1", "X-ClawGate-Issuer-Key-Id": keyId,
    "X-ClawGate-Issuer-Signature": sign(null, pollSigningBytes({ method: "GET", uri, challenge, status, keyId, body }), privateKey).toString("base64") });
  return { publicKeyHex: pin, challenge, uri, status, headers, body };
}
test("verified bridge bytes bind event identity; JSON copies cannot mint capability", () => {
  const response = verifyPollResponse(envelope());
  assert.equal(verifiedBridgeAdmission(response.events[0]).provenance, "watcher_accepted");
  assert.equal(verifiedBridgeAdmission(structuredClone(response.events[0])), null);
});
test("verified events cannot retain admission while their signed content is mutated", () => {
  const response = verifyPollResponse(envelope());
  const verified = response.events[0];
  assert.throws(() => { verified.payload.text = "changed"; }, TypeError);
  assert.throws(() => { verified.adapter = "debug"; }, TypeError);
  assert.throws(() => { verified.admission.provenance = "unknown"; }, TypeError);
  assert.throws(() => { response.events.push(event); }, TypeError);
  assert.equal(verified.payload.text, "fixture");
  assert.equal(verifiedBridgeAdmission(verified).provenance, "watcher_accepted");
});
test("changed body, challenge, URI, status or pin is rejected", () => {
  const env = envelope();
  for (const patch of [{ body: Buffer.from(env.body.toString().replace("fixture", "changed")) },
    { challenge: "b".repeat(64) }, { uri: "/v1/poll?since=3" }, { status: 201 }, { publicKeyHex: "0".repeat(64) }]) {
    assert.throws(() => verifyPollResponse({ ...env, ...patch }));
  }
});
test("signed mismatched identity and duplicate admission are rejected; debug remains debug", () => {
  assert.throws(() => verifyPollResponse(envelope([{ ...event, admission: { ...event.admission, event_id: 6 } }])));
  assert.throws(() => verifyPollResponse(envelope([event, event])));
  const response = verifyPollResponse(envelope([{ ...event, admission: { ...event.admission, provenance: "debug_injected" } }]));
  assert.equal(verifiedBridgeAdmission(response.events[0]).provenance, "debug_injected");
});

test("original poll evidence retains exact bytes and immutable request binding", () => {
  const unknown = { id: 9, type: "inbound_message", adapter: "debug", observedAt: "2026-01-01T00:00:01Z", payload: { text: "raw" } };
  const admitted = { ...event, id: 10, admission: { ...event.admission, event_id: 10 } };
  const rawBody = Buffer.from(`{\n  "next_cursor": 10, "events": [${JSON.stringify(unknown)}, ${JSON.stringify(admitted)}], "ok": true\n}`);
  const headers = new Headers({ "X-ClawGate-Issuer-Version": "1", "X-ClawGate-Issuer-Key-Id": keyId,
    "X-ClawGate-Issuer-Signature": sign(null, pollSigningBytes({ method: "GET", uri, challenge, status, keyId, body: rawBody }), privateKey).toString("base64") });
  const response = verifyPollResponse({ publicKeyHex: pin, challenge, uri, status, headers, body: rawBody });
  const first = verifiedBridgePollEvidence(response.events[0]);
  const second = verifiedBridgePollEvidence(response.events[1]);
  assert.equal(first.eventIndex, 0);
  assert.equal(second.eventIndex, 1);
  assert.strictEqual(first.envelope, second.envelope);
  assert.equal(first.envelope.bodyBase64, rawBody.toString("base64"));
  assert.equal(first.envelope.responseHeaders.issuerKeyId, keyId);
  assert.equal(first.envelope.method, "GET");
  assert.equal(first.envelope.uri, uri);
  assert.equal(first.envelope.challenge, challenge);
  assert.equal(first.envelope.status, status);
  assert.equal(verifiedBridgeAdmission(response.events[0]), null);
  assert.equal(verifiedBridgePollEvidence({ ...response.events[0], payload: { merged: true } }), null);
  assert.equal(verifiedBridgePollEvidence(structuredClone(response.events[1])), null);
  rawBody[0] = 0x58;
  headers.set("X-ClawGate-Issuer-Signature", "changed");
  headers.set("X-ClawGate-Issuer-Key-Id", "changed");
  assert.equal(first.envelope.bodyBase64, Buffer.from(`{\n  "next_cursor": 10, "events": [${JSON.stringify(unknown)}, ${JSON.stringify(admitted)}], "ok": true\n}`).toString("base64"));
  assert.equal(first.envelope.responseHeaders.issuerSignature, sign(null, pollSigningBytes({ method: "GET", uri, challenge, status, keyId, body: Buffer.from(`{\n  "next_cursor": 10, "events": [${JSON.stringify(unknown)}, ${JSON.stringify(admitted)}], "ok": true\n}`) }), privateKey).toString("base64"));
});

test("Swift/Node shared exact-byte vector and unknown sentinel remain compatible", () => {
  const f = JSON.parse(readFileSync(new URL("../../../../Tests/Fixtures/bridge-poll-signing-v1.json", import.meta.url)));
  const body = Buffer.from(f.body);
  assert.equal(pollSigningBytes({ ...f, body }).toString("hex"), f.signingBytesHex);
  const headers = new Headers({ "X-ClawGate-Issuer-Version": "1", "X-ClawGate-Issuer-Key-Id": f.keyId,
    "X-ClawGate-Issuer-Signature": f.signatureBase64 });
  assert.equal(verifyPollResponse({ ...f, headers, body }).events.length, 0);
  const response = verifyPollResponse(envelope([{ ...event, admission: { ...event.admission,
    admission_id: "unknown", generation: "unknown", provenance: "unknown", issuer_key_id: null, failure_reason: "not_issued" } }]));
  assert.equal(verifiedBridgeAdmission(response.events[0]).provenance, "unknown");
});

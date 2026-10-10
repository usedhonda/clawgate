import { createHash, createPublicKey, randomBytes, verify } from "node:crypto";

// Public pin verification establishes bridge origin, not message author or RPC authority.
const admittedEvents = new WeakMap();
const hex64 = /^[a-f0-9]{64}$/;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
function freezeJson(value) {
  if (value && typeof value === "object") {
    for (const child of Object.values(value)) freezeJson(child);
    Object.freeze(value);
  }
  return value;
}
export const createPollChallenge = () => randomBytes(32).toString("hex");
export function pollSigningBytes({ method, uri, challenge, status, keyId, body }) {
  const values = [method, uri, challenge, String(status), keyId,
    createHash("sha256").update(body).digest("hex")];
  return Buffer.concat([Buffer.from("clawgate.poll.v1"), ...values.flatMap(value => {
    const bytes = Buffer.from(value, "utf8");
    const length = Buffer.alloc(4); length.writeUInt32BE(bytes.length);
    return [length, bytes];
  })]);
}

export function verifyPollResponse({ publicKeyHex, challenge, uri, status, headers, body }) {
  if (!hex64.test(publicKeyHex || "") || !hex64.test(challenge || "")) {
    throw new Error("bridge_poll_invalid_pin_or_challenge");
  }
  const raw = Buffer.from(publicKeyHex, "hex");
  const keyId = createHash("sha256").update(raw).digest("hex");
  const signatureText = headers.get("x-clawgate-issuer-signature") || "";
  const signature = Buffer.from(signatureText, "base64");
  if (status !== 200 || headers.get("x-clawgate-issuer-version") !== "1"
      || headers.get("x-clawgate-issuer-key-id") !== keyId
      || signature.length !== 64 || signature.toString("base64") !== signatureText) {
    throw new Error("bridge_poll_invalid_envelope");
  }
  // RFC8410 Ed25519 SubjectPublicKeyInfo prefix followed by exactly32 raw bytes.
  const key = createPublicKey({ key: Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"), raw,
  ]), type: "spki", format: "der" });
  if (!verify(null, pollSigningBytes({ method: "GET", uri, challenge, status, keyId, body }), key, signature)) {
    throw new Error("bridge_poll_signature_rejected");
  }
  const response = JSON.parse(body.toString("utf8"));
  if (response.ok !== true || !Array.isArray(response.events)
      || !Number.isSafeInteger(response.next_cursor) || response.next_cursor < 0) {
    throw new Error("bridge_poll_invalid_response");
  }
  const seen = new Set();
  for (const event of response.events) {
    const a = event.admission;
    if (!a) continue; // No protected identity is still unknown, never inferred from adapter.
    const expected = ["admission_id", "generation", "event_id", "event_type", "adapter", "observed_at", "provenance"];
    const allowed = new Set([...expected, "issuer_key_id", "failure_reason"]);
    if (typeof a !== "object" || Array.isArray(a) || Object.keys(a).some(k => !allowed.has(k))
        || expected.some(k => !(k in a))
        || !(uuid.test(a.admission_id) || (a.provenance === "unknown" && a.admission_id === "unknown"))
        || !(uuid.test(a.generation) || (a.provenance === "unknown" && ["unavailable", "unknown"].includes(a.generation)))
        || !Number.isSafeInteger(a.event_id) || a.event_id !== event.id
        || a.event_type !== event.type || a.adapter !== event.adapter || a.observed_at !== event.observedAt
        || !["watcher_accepted", "debug_injected", "unknown"].includes(a.provenance)
        || (a.provenance !== "unknown" && (a.issuer_key_id !== keyId || a.failure_reason != null))
        || (a.provenance !== "unknown" && seen.has(a.admission_id))) {
      throw new Error("bridge_poll_invalid_admission");
    }
    if (a.provenance !== "unknown") seen.add(a.admission_id);
    const proof = Object.freeze({ ...a, responseKeyId: keyId });
    admittedEvents.set(event, proof);
  }
  // Retain the exact signed projection: a verified object must not later carry
  // different content while retaining its WeakMap admission capability.
  return freezeJson(response);
}

// WeakMap binding cannot be minted by ReplyPayload, event.extra or a copied JSON object.
export function verifiedBridgeAdmission(event) {
  return event && typeof event === "object" ? admittedEvents.get(event) ?? null : null;
}

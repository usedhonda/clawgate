import { createHash, randomUUID } from "node:crypto";

/**
 * Companion Vibeterm audio for confirmed LINE conversation replies.
 * Routing origin is an actual LINE ingress session, never merely a LINE sink.
 */
let requestGateway = null;

function warn(log, message) {
  if (log?.warn) log.warn(message);
  else console.warn(message);
}

export function setLineReplyTtsRuntime(runtime) {
  requestGateway = runtime?.gateway?.request?.bind(runtime.gateway) || null;
}

export function isLineConversationSession(sessionKey) {
  return typeof sessionKey === "string" && /^agent:[^:]+:clawgate:line:/.test(sessionKey);
}

export function queueConfirmedLineReplyTts({ text, messageId, traceId, emitText = false, log }) {
  if (!requestGateway) {
    warn(log, "clawgate: LINE reply Vibeterm TTS skipped: gateway runtime unavailable");
    return;
  }
  // LINE was already sent. Do not make its success or the next poll wait for
  // VOICEVOX synthesis/WS delivery.
  void Promise.resolve().then(() =>
    requestGateway("line.reply-tts", { text, messageId, traceId, ...(emitText ? { emitText: true } : {}) })
  ).catch((err) => {
    warn(log, `clawgate: LINE reply Vibeterm TTS failed (trace=${traceId || "none"}, class=${err?.name || "Error"})`);
  });
}

// Wire preparation alone does not establish admission provenance. Protected
// callers explicitly enable the durable owner; legacy handles remain inert.
const expectations = new WeakSet();
const semanticCalls = new WeakMap();
const wireOrigins = new Set(["line_conversation", "typed_chat", "proactive", "recall", "cron", "tproj", "unknown"]);
const disabledResult = Object.freeze({ enabled: false, status: "disabled" });
const invalidHandleResult = Object.freeze({ enabled: false, status: "invalid_handle" });
const invalidConfirmationResult = Object.freeze({ enabled: false, status: "invalid_confirmation" });

function provenance(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

export function createLineReplyExpectation({ text, admittedOrigin, sourceReplySessionKey, policySessionKey, enabled = false, emitText = false }) {
  if (typeof text !== "string" || text.length > 16384) {
    return null;
  }
  const handle = Object.freeze({
    replyCorrelationId: randomUUID(),
    semanticReplyFingerprint: createHash("sha256").update(text, "utf8").digest("hex"),
    textLength: text.length,
    admittedOrigin: provenance(admittedOrigin),
    sourceReplySessionKey: provenance(sourceReplySessionKey),
    policySessionKey: provenance(policySessionKey),
  });
  expectations.add(handle);
  if (enabled === true) semanticCalls.set(handle, { text, request: requestGateway, emitText: emitText === true });
  return handle;
}

export function observeLineReplyExpectation(handle) {
  if (handle == null) return disabledResult;
  if (!expectations.has(handle)) return invalidHandleResult;
  const call = semanticCalls.get(handle);
  if (!call) return disabledResult;
  call.observation ??= Promise.resolve().then(async () => {
    const packet = serializeLineReplyExpectation(handle);
    if (!call.request || !packet) return { status: "unavailable" };
    return await call.request("line.reply-tts", packet);
  }).catch(() => ({ status: "unavailable" }));
  return call.observation;
}

// Closed Gateway expect shape. Host-owned verified admission carry supplies
// provenance; event payloads and destination heuristics must not replace it.
export function serializeLineReplyExpectation(handle) {
  if (!handle || !expectations.has(handle)) return null;
  const sessions = [handle.sourceReplySessionKey, handle.policySessionKey];
  if (sessions.some(value => value !== null &&
      (typeof value !== "string" || value.length === 0 || value.length > 512))) return null;
  return Object.freeze({
    version: 1,
    phase: "expect",
    replyCorrelationId: handle.replyCorrelationId,
    admittedOrigin: wireOrigins.has(handle.admittedOrigin) ? handle.admittedOrigin : "unknown",
    sourceReplySessionKey: handle.sourceReplySessionKey,
    policySessionKey: handle.policySessionKey,
    semanticReplyFingerprint: handle.semanticReplyFingerprint,
  });
}

export function confirmLineReplyExpectation(handle, confirmation = {}) {
  if (handle == null) return disabledResult;
  if (!expectations.has(handle)) return invalidHandleResult;
  const { messageId, deliveredChannel, textConfirmedAtMs } = confirmation ?? {};
  // Actual bridge IDs only: no generated fallback, controls, or markup.
  if (typeof messageId !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(messageId)
      || deliveredChannel !== "line"
      || !Number.isSafeInteger(textConfirmedAtMs) || textConfirmedAtMs <= 0) {
    return invalidConfirmationResult;
  }
  const call = semanticCalls.get(handle);
  if (!call) return disabledResult;
  if (call.messageId !== undefined && (call.messageId !== messageId || call.confirmedAt !== textConfirmedAtMs)) {
    return invalidConfirmationResult;
  }
  call.messageId = messageId;
  call.confirmedAt = textConfirmedAtMs;
  call.confirmation ??= Promise.resolve().then(async () => {
    const observed = await observeLineReplyExpectation(handle);
    if (!["accepted", "duplicate"].includes(observed?.status)) return { status: "unknown" };
    const confirmed = await call.request("line.reply-tts", {
      version: 1, phase: "confirmed", replyCorrelationId: handle.replyCorrelationId,
      confirmedMessageId: messageId, deliveredChannel: "line", textConfirmedAtMs,
    });
    if (!["accepted", "duplicate"].includes(confirmed?.status)) return { status: "unknown" };
    if (confirmed.expectedAudio !== "required") return { status: "ineligible", expectedAudio: confirmed.expectedAudio };
    return await call.request("line.reply-tts", {
      version: 1, phase: "handoff", replyCorrelationId: handle.replyCorrelationId,
      text: call.text, emitText: call.emitText,
    });
  }).catch(() => ({ status: "unknown" }));
  return call.confirmation;
}

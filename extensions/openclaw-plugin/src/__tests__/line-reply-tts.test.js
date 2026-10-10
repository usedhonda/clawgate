import { afterEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  setLineReplyTtsRuntime, isLineConversationSession, queueConfirmedLineReplyTts,
  createLineReplyExpectation, observeLineReplyExpectation, confirmLineReplyExpectation,
} from "../line-reply-tts.js";

const flush = () => new Promise((resolve) => setImmediate(resolve));
afterEach(() => setLineReplyTtsRuntime(null));

describe("installed LINE companion behavior", () => {
  it("recognizes LINE ingress session keys only", () => {
    assert.equal(isLineConversationSession("agent:main:clawgate:line:room"), true);
    for (const key of [null, "line:room", "agent:main:clawgate:default:room", "agent:main:telegram:room"]) {
      assert.equal(isLineConversationSession(key), false);
    }
  });
  it("queues legacy request asynchronously and preserves optional emitText", async () => {
    const requests = [];
    const gateway = { request(method, params) { assert.equal(this, gateway); requests.push({ method, params }); } };
    setLineReplyTtsRuntime({ gateway });
    queueConfirmedLineReplyTts({ text: "reply", messageId: "actual-1", traceId: "trace-1" });
    assert.equal(requests.length, 0);
    await flush();
    assert.deepEqual(requests[0], { method: "line.reply-tts", params: { text: "reply", messageId: "actual-1", traceId: "trace-1" } });
    queueConfirmedLineReplyTts({ text: "reply", messageId: "actual-2", traceId: "trace-2", emitText: true });
    await flush();
    assert.equal(requests[1].params.emitText, true);
  });
  it("warns when unavailable and catches legacy async failures without reply body", async () => {
    const warnings = [];
    const log = { warn: (value) => warnings.push(value) };
    queueConfirmedLineReplyTts({ text: "private-body", log });
    assert.match(warnings[0], /runtime unavailable/);
    setLineReplyTtsRuntime({ gateway: { request: async () => { throw new TypeError("private-body"); } } });
    queueConfirmedLineReplyTts({ text: "private-body", traceId: "trace-1", log });
    await flush();
    assert.match(warnings[1], /class=TypeError/);
    assert.equal(warnings.some((warning) => warning.includes("private-body")), false);
  });
});

describe("disabled LINE semantic observation", () => {
  it("mints one stable immutable body-free UUID handle per expectation", () => {
    const handle = createLineReplyExpectation({ text: "private-body", admittedOrigin: "unresolved", sourceReplySessionKey: "source", policySessionKey: "policy" });
    assert.equal(Object.isFrozen(handle), true);
    assert.match(handle.replyCorrelationId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    const id = handle.replyCorrelationId;
    observeLineReplyExpectation(handle);
    confirmLineReplyExpectation(handle, { messageId: "actual-1", deliveredChannel: "line", textConfirmedAtMs: 1 });
    assert.equal(handle.replyCorrelationId, id);
    assert.throws(() => { handle.replyCorrelationId = "replacement"; }, TypeError);
    assert.equal(JSON.stringify(handle).includes("private-body"), false);
    assert.equal(Object.hasOwn(handle, "text"), false);
    assert.notEqual(createLineReplyExpectation({ text: "private-body" }).replyCorrelationId, id);
  });
  it("hashes exact UTF8 bytes without normalization", () => {
    for (const text of ["é", "e\u0301", " 日本語🚂\r\n", "\ud800"]) {
      const handle = createLineReplyExpectation({ text });
      assert.equal(handle.semanticReplyFingerprint, createHash("sha256").update(Buffer.from(text, "utf8")).digest("hex"));
      assert.equal(handle.textLength, text.length);
    }
    assert.notEqual(createLineReplyExpectation({ text: "é" }).semanticReplyFingerprint, createLineReplyExpectation({ text: "e\u0301" }).semanticReplyFingerprint);
  });
  it("uses UTF16 bounds and returns null without disturbing legacy routing", () => {
    assert.ok(createLineReplyExpectation({ text: "🚂".repeat(8192) }));
    for (const text of ["🚂".repeat(8193), "x".repeat(16385), null, 2, {}]) {
      assert.equal(createLineReplyExpectation({ text }), null);
    }
    assert.equal(observeLineReplyExpectation(null).status, "disabled");
    assert.equal(confirmLineReplyExpectation(null).status, "disabled");
  });
  it("leaves missing or malformed provenance unknown instead of inferring LINE", () => {
    const handle = createLineReplyExpectation({ text: "reply", policySessionKey: "agent:main:clawgate:line:room" });
    assert.equal(handle.admittedOrigin, null);
    assert.equal(handle.sourceReplySessionKey, null);
    assert.equal(handle.policySessionKey, "agent:main:clawgate:line:room");
    const malformed = createLineReplyExpectation({ text: "reply", admittedOrigin: { type: "line" }, sourceReplySessionKey: "" });
    assert.equal(malformed.admittedOrigin, null);
    assert.equal(malformed.sourceReplySessionKey, null);
  });
  it("never makes RPC for valid or invalid semantic calls with runtime installed", async () => {
    let rpcCount = 0;
    setLineReplyTtsRuntime({ gateway: { request() { rpcCount += 1; } } });
    const handle = createLineReplyExpectation({ text: "reply" });
    assert.deepEqual(observeLineReplyExpectation(handle), { enabled: false, status: "disabled" });
    const valid = { messageId: "actual_1:part.2-3", deliveredChannel: "line", textConfirmedAtMs: 1 };
    assert.equal(confirmLineReplyExpectation(handle, valid).status, "disabled");
    for (const messageId of [undefined, "", "a".repeat(129), "非ASCII", "actual\n", "has space", "<markup>"]) {
      assert.equal(confirmLineReplyExpectation(handle, { ...valid, messageId }).status, "invalid_confirmation");
    }
    for (const textConfirmedAtMs of [0, -1, NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1, "1"]) {
      assert.equal(confirmLineReplyExpectation(handle, { ...valid, textConfirmedAtMs }).status, "invalid_confirmation");
    }
    assert.equal(confirmLineReplyExpectation(handle, { ...valid, deliveredChannel: "telegram" }).status, "invalid_confirmation");
    assert.equal(confirmLineReplyExpectation(handle, null).status, "invalid_confirmation");
    assert.equal(observeLineReplyExpectation({ ...handle }).status, "invalid_handle");
    await flush();
    assert.equal(rpcCount, 0);
  });
});

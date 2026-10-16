import assert from "node:assert/strict";
import { test } from "node:test";
import { handleInboundMessage, setGatewayRuntime } from "../gateway.js";

test("deferred reply callbacks own transport settlement and preserve ingress routing", async () => {
  let deliver;
  const sends = [];
  const traces = [];
  let settleSend;
  let outcome = "pending";
  setGatewayRuntime({
    config: { current: () => ({ agents: { entries: { fixture: {} } } }) },
    channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async (params) => {
      deliver = params.dispatcherOptions.deliver;
      return { deferredToActiveRun: "followup" };
    } } },
  });
  const sendTmuxMessage = async (...args) => {
    sends.push(args);
    if (outcome === "pending") return await new Promise((resolve) => { settleSend = resolve; });
    if (outcome === "throw") throw new Error("fixture transport unavailable");
    return { ok: false };
  };
  const handle = (adapter) => handleInboundMessage({
    event: { id: "fixture-input", adapter, payload: { text: "fixture input", conversation: "fixture conversation" } },
    accountId: "fixture", cfg: {}, defaultConversation: "fixture conversation",
    log: { info: (entry) => traces.push(entry), error: () => {} }, sendTmuxMessage,
  });
  await handle("line");
  assert.equal(sends.length, 0);
  let callbackSettled = false;
  const sent = deliver({ text: "fixture deferred reply" }).then(() => { callbackSettled = true; });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(sends.length, 1);
  assert.equal(sends[0][3].channel, "line");
  assert.equal(callbackSettled, false);
  settleSend({ ok: true, result: { message_id: "fixture-result" } });
  await sent;
  assert.equal(callbackSettled, true);
  outcome = "negative";
  await assert.rejects(deliver({ text: "fixture rejected reply" }), /did not confirm/);
  outcome = "throw";
  await assert.rejects(deliver({ text: "fixture unavailable reply" }), /transport unavailable/);
  await handle("telegram");
  await assert.rejects(deliver({ text: "fixture telegram reply" }), /transport unavailable/);
  assert.equal(sends.at(-1)[3].channel, "telegram");
  assert.equal(sends.length, 4);
  assert.ok(traces.some((entry) => entry.includes('"status":"accepted"')));
});

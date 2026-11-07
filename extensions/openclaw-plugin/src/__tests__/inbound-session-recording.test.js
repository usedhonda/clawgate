import assert from "node:assert/strict";
import test from "node:test";
import { handleInboundMessage, setGatewayRuntime } from "../gateway.js";

test("inbound dispatch resolves the owning agent's store through the host session API", async () => {
  const cfg = { agents: { entries: { fixture: {} } }, session: { store: "/fixture/{agentId}/sessions.json" } };
  const calls = [];
  const records = [];
  const runtime = {
    config: { current: () => cfg },
    agent: { session: { resolveStorePath: (store, options) => {
      calls.push({ store, options });
      return "/fixture/fixture/sessions.json";
    } } },
    channel: {
      session: { recordInboundSession: async (params) => { records.push(params); } },
      reply: { dispatchReplyWithBufferedBlockDispatcher: async () => {
        assert.equal(records.length, 1, "session is recorded before reply dispatch");
        return { deferredToActiveRun: "followup" };
      } },
    },
  };
  setGatewayRuntime(runtime);
  const handle = () => handleInboundMessage({
    event: { id: "fixture-session-input", adapter: "line", payload: { text: "fixture input", conversation: "Fixture Conversation" } },
    accountId: "default", cfg,
  });
  await handle();
  assert.deepEqual(calls, [{ store: cfg.session.store, options: { agentId: "fixture" } }]);
  assert.equal(records[0].sessionKey, "agent:fixture:clawgate:default:fixture conversation");
  assert.equal(records[0].storePath, "/fixture/fixture/sessions.json");
  assert.equal(records[0].ctx.CommandAuthorized, false, "screen input remains untrusted");
  assert.deepEqual(records[0].updateLastRoute, {
    sessionKey: records[0].sessionKey, channel: "clawgate", to: "Fixture Conversation", accountId: "default",
  });

  // Older hosts expose the same resolver under channel.session.
  runtime.channel.session.resolveStorePath = runtime.agent.session.resolveStorePath;
  delete runtime.agent;
  calls.length = 0;
  records.length = 0;
  await handle();
  assert.equal(calls.length, 1);
  assert.equal(records.length, 1);
});

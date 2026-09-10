import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { buildMsgContext, setGatewayRuntime, resolveSessionAgentId, buildTmuxSessionKey } from "../gateway.js";

// Inline copies of outbound.js's private consumer logic (not exported — see the
// drift-risk note in line-ingress-noise-filter.test.js for the established
// pattern). Keep byte-identical to outbound.js.
function devLanePaneProjectFromKey(sessionKey) {
  if (!sessionKey || !sessionKey.includes(":tmux:")) return null;
  return sessionKey.split(":tmux:")[1] || null;
}
function tprojOriginConversationFromKey(sessionKey) {
  if (!sessionKey || !sessionKey.includes(":")) return null;
  return sessionKey.split(":").pop() || null;
}

function stubRuntime(agentEntries) {
  return {
    config: {
      current: () => ({ agents: { entries: agentEntries } }),
    },
  };
}

describe("SessionKey canonical shape (8.x assertCanonicalSessionKeyWrite contract)", () => {
  it("resolveSessionAgentId reads the first configured agent id", () => {
    setGatewayRuntime(stubRuntime({ main: {} }));
    assert.equal(resolveSessionAgentId(), "main");
  });

  it("resolveSessionAgentId falls back to 'main' when no agents are configured", () => {
    setGatewayRuntime(stubRuntime(undefined));
    assert.equal(resolveSessionAgentId(), "main");
  });

  it("buildMsgContext emits an agent-prefixed, lowercase SessionKey for a LINE inbound event", () => {
    setGatewayRuntime(stubRuntime({ main: {} }));
    const event = {
      id: "evt-1",
      payload: {
        conversation: "Test Conversation",
        sender: "Test Conversation",
        text: "hello",
        source: "poll",
      },
    };
    const ctx = buildMsgContext(event, "line", undefined);
    // Must carry the `agent:<agentId>:` prefix required by
    // session-canonical-key.ts assertCanonicalSessionKeyWrite, and must already be
    // lowercase since clawgate is not in the case-preserving-peer registry.
    assert.equal(ctx.SessionKey, "agent:main:clawgate:line:test conversation");
  });

  it("buildMsgContext SessionKey is idempotent under lowercasing (canonical form)", () => {
    setGatewayRuntime(stubRuntime({ main: {} }));
    const event = {
      id: "evt-2",
      payload: { conversation: "MiXeD CaSe", sender: "MiXeD CaSe", text: "hi" },
    };
    const ctx = buildMsgContext(event, "default", undefined);
    assert.equal(ctx.SessionKey, ctx.SessionKey.toLowerCase());
    assert.match(ctx.SessionKey, /^agent:[^:]+:clawgate:default:/);
  });

  it("buildTmuxSessionKey emits an agent-prefixed key with the project segment preserved verbatim", () => {
    setGatewayRuntime(stubRuntime({ main: {} }));
    const key = buildTmuxSessionKey("default", "MyMixedCaseProject");
    assert.equal(key, "agent:main:clawgate:default:tmux:MyMixedCaseProject");
    // Deliberately not lowercased end-to-end (unlike the LINE key) -- see the
    // comment on buildTmuxSessionKey().
    assert.notEqual(key, key.toLowerCase());
  });

  it("devLanePaneProject's :tmux: split still recovers the exact original-case project from the new prefixed key", () => {
    setGatewayRuntime(stubRuntime({ main: {} }));
    const key = buildTmuxSessionKey("default", "Hybrix");
    assert.equal(devLanePaneProjectFromKey(key), "Hybrix");
  });

  it("tprojOriginForSessionKey's trailing-segment split is unaffected by the new agent: prefix", () => {
    setGatewayRuntime(stubRuntime({ main: {} }));
    const key = buildTmuxSessionKey("default", "oc-general");
    assert.equal(tprojOriginConversationFromKey(key), "oc-general");
  });
});

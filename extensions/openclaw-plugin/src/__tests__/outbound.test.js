/**
 * Tests for outbound.js conversation_hint mapping logic.
 *
 * The critical behavior: special "to" values ("LINE", "default", "clawgate:*")
 * must be mapped to account.defaultConversation before being sent to ClawGate.
 */

import { describe, it, beforeEach, mock } from "node:test";
import assert from "node:assert/strict";

// --- Stubs -----------------------------------------------------------

let stubAccount = {};
let lastSendArgs = null;
let lastTmuxArgs = null;

// Mock config.js
mock.module("../config.js", {
  namedExports: {
    resolveAccount: (_cfg, _id) => stubAccount,
  },
});

// Mock client.js
mock.module("../client.js", {
  namedExports: {
    setClawgateAuthToken: () => {},
    clawgateSend: async (_apiUrl, conversationHint, text) => {
      lastSendArgs = { conversationHint, text };
      return { ok: true, result: { message_id: "test-1", timestamp: new Date().toISOString() } };
    },
    clawgateTmuxSend: async (_apiUrl, project, text) => {
      lastTmuxArgs = { project, text };
      return { ok: true, result: { message_id: "tmux-1", timestamp: new Date().toISOString() } };
    },
  },
});

// Mock shared-state.js
let stubSessionMode = "ignore";
mock.module("../shared-state.js", {
  namedExports: {
    getActiveProject: () => ({ project: "", sessionType: "claude_code" }),
    getSessionMode: (_project) => stubSessionMode,
  },
});

// Import after mocks are installed
const { outbound } = await import("../outbound.js");

// --- Helpers ---------------------------------------------------------

function makeAccount(overrides = {}) {
  return {
    token: "",
    apiUrl: "http://127.0.0.1:8765",
    defaultConversation: "Alice Smith",
    ...overrides,
  };
}

const baseSendParams = { text: "hello", accountId: "default", cfg: {} };

// --- Tests -----------------------------------------------------------

describe("outbound conversation_hint mapping", () => {
  beforeEach(() => {
    lastSendArgs = null;
    lastTmuxArgs = null;
    stubSessionMode = "ignore";
    stubAccount = makeAccount();
  });

  // --- sendText ---

  describe("sendText", () => {
    it('maps to="LINE" to defaultConversation', async () => {
      await outbound.sendText({ ...baseSendParams, to: "LINE" });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
    });

    it('maps to="default" to defaultConversation', async () => {
      await outbound.sendText({ ...baseSendParams, to: "default" });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
    });

    it('maps to="clawgate:default" to defaultConversation', async () => {
      await outbound.sendText({ ...baseSendParams, to: "clawgate:default" });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
    });

    it("passes explicit conversation name through unchanged", async () => {
      await outbound.sendText({ ...baseSendParams, to: "Test User" });
      assert.equal(lastSendArgs.conversationHint, "Test User");
    });

    it('falls back to raw "to" when defaultConversation is empty', async () => {
      stubAccount = makeAccount({ defaultConversation: "" });
      await outbound.sendText({ ...baseSendParams, to: "LINE" });
      assert.equal(lastSendArgs.conversationHint, "LINE");
    });
  });

  // --- sendMedia ---

  describe("sendMedia", () => {
    it('maps to="LINE" to defaultConversation', async () => {
      await outbound.sendMedia({ ...baseSendParams, to: "LINE", mediaUrl: null });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
    });

    it('maps to="default" to defaultConversation', async () => {
      await outbound.sendMedia({ ...baseSendParams, to: "default", mediaUrl: null });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
    });

    it("passes explicit conversation name through unchanged", async () => {
      await outbound.sendMedia({ ...baseSendParams, to: "Work Group", mediaUrl: null });
      assert.equal(lastSendArgs.conversationHint, "Work Group");
    });

    it('falls back to raw "to" when defaultConversation is empty', async () => {
      stubAccount = makeAccount({ defaultConversation: "" });
      await outbound.sendMedia({ ...baseSendParams, to: "LINE", mediaUrl: null });
      assert.equal(lastSendArgs.conversationHint, "LINE");
    });
  });

  // --- dev-lane sessionKey routing (autonomous/auto -> pane, observe -> LINE) ---

  describe("dev-lane sessionKey routing (SPEC-messaging.md §6)", () => {
    const TMUX_KEY = "clawgate:default:tmux:oc-general";

    it("autonomous tmux sessionKey routes to pane (clawgateTmuxSend), NOT LINE", async () => {
      stubSessionMode = "autonomous";
      await outbound.sendText({ ...baseSendParams, to: "LINE", sessionKey: TMUX_KEY });
      assert.equal(lastTmuxArgs.project, "oc-general");
      assert.equal(lastTmuxArgs.text, "hello");
      assert.equal(lastSendArgs, null); // LINE send must NOT happen
    });

    it("auto tmux sessionKey routes to pane", async () => {
      stubSessionMode = "auto";
      await outbound.sendText({ ...baseSendParams, to: "LINE", sessionKey: TMUX_KEY });
      assert.equal(lastTmuxArgs.project, "oc-general");
      assert.equal(lastSendArgs, null);
    });

    it("observe tmux sessionKey stays on LINE, NOT pane", async () => {
      stubSessionMode = "observe";
      await outbound.sendText({ ...baseSendParams, to: "LINE", sessionKey: TMUX_KEY });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
      assert.equal(lastTmuxArgs, null); // observe must NOT be redirected to pane
    });

    it("no sessionKey stays on LINE (secretary/normal conversation unchanged)", async () => {
      await outbound.sendText({ ...baseSendParams, to: "LINE" });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
      assert.equal(lastTmuxArgs, null);
    });

    it("non-tmux sessionKey stays on LINE regardless of mode", async () => {
      stubSessionMode = "autonomous";
      await outbound.sendText({ ...baseSendParams, to: "LINE", sessionKey: "clawgate:line:Alice Smith" });
      assert.equal(lastSendArgs.conversationHint, "Alice Smith");
      assert.equal(lastTmuxArgs, null);
    });

    it("sendMedia with autonomous tmux sessionKey routes caption to pane", async () => {
      stubSessionMode = "autonomous";
      await outbound.sendMedia({ ...baseSendParams, to: "LINE", mediaUrl: null, sessionKey: TMUX_KEY });
      assert.equal(lastTmuxArgs.project, "oc-general");
      assert.equal(lastTmuxArgs.text, "hello");
      assert.equal(lastSendArgs, null);
    });
  });
});

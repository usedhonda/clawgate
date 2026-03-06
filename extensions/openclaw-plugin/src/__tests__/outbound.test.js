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
  },
});

// Mock shared-state.js
mock.module("../shared-state.js", {
  namedExports: {
    getActiveProject: () => ({ project: "", sessionType: "claude_code" }),
  },
});

// Import after mocks are installed
const { outbound } = await import("../outbound.js");

// --- Helpers ---------------------------------------------------------

function makeAccount(overrides = {}) {
  return {
    token: "",
    apiUrl: "http://127.0.0.1:8765",
    defaultConversation: "Yuzuru Honda",
    ...overrides,
  };
}

const baseSendParams = { text: "hello", accountId: "default", cfg: {} };

// --- Tests -----------------------------------------------------------

describe("outbound conversation_hint mapping", () => {
  beforeEach(() => {
    lastSendArgs = null;
    stubAccount = makeAccount();
  });

  // --- sendText ---

  describe("sendText", () => {
    it('maps to="LINE" to defaultConversation', async () => {
      await outbound.sendText({ ...baseSendParams, to: "LINE" });
      assert.equal(lastSendArgs.conversationHint, "Yuzuru Honda");
    });

    it('maps to="default" to defaultConversation', async () => {
      await outbound.sendText({ ...baseSendParams, to: "default" });
      assert.equal(lastSendArgs.conversationHint, "Yuzuru Honda");
    });

    it('maps to="clawgate:default" to defaultConversation', async () => {
      await outbound.sendText({ ...baseSendParams, to: "clawgate:default" });
      assert.equal(lastSendArgs.conversationHint, "Yuzuru Honda");
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
      assert.equal(lastSendArgs.conversationHint, "Yuzuru Honda");
    });

    it('maps to="default" to defaultConversation', async () => {
      await outbound.sendMedia({ ...baseSendParams, to: "default", mediaUrl: null });
      assert.equal(lastSendArgs.conversationHint, "Yuzuru Honda");
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
});

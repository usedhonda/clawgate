/**
 * Outbound adapter — sends AI replies to LINE via ClawGate.
 */

import { resolveAccount } from "./config.js";
import { clawgateSend, clawgateTmuxSend, setClawgateAuthToken } from "./client.js";
import { getSessionMode, enqueueDevLaneText } from "./shared-state.js";

/**
 * For a dev-lane tmux session in autonomous/auto mode, return the project name
 * (= pane target) so the reply is routed back to the originating CC session via
 * adapter=tmux instead of the user's LINE. Returns null for observe (→ LINE),
 * non-tmux sessionKeys, or unknown mode. The mode lives in the plugin
 * (gateway.js sessionModes, mirrored into shared-state); core only propagates
 * the source sessionKey. See SPEC-messaging.md §6.
 * @param {string|undefined} sessionKey  e.g. "clawgate:default:tmux:oc-general"
 * @returns {string|null} project name when the reply must go to the pane, else null
 */
function devLanePaneProject(sessionKey) {
  if (!sessionKey || !sessionKey.includes(":tmux:")) return null;
  const project = sessionKey.split(":tmux:")[1];
  if (!project) return null;
  const mode = getSessionMode(project);
  return (mode === "autonomous" || mode === "auto") ? project : null;
}

// Retriable 503 codes the Host B (ClawGate Swift) tmux adapter returns when the
// pane is busy / typing / momentarily not found — it does NOT queue these, so we
// retry via the gateway pendingTaskQueue instead of dropping the reply.
const REDIRECT_RETRIABLE_CODES = new Set(["session_busy", "session_typing_busy", "session_not_found"]);

/**
 * Send a dev-lane (autonomous/auto tmux) reply to the originating CC session pane.
 * Prefixes the body with the canonical OpenClaw-origin tag (same format as
 * gateway.js cc_task: "[from:OpenClaw Agent - {Mode}] {body}") so CC/Codex treat
 * it as OpenClaw-origin. On a retriable 503 (pane busy) the prefixed text is
 * queued for idle retry via the gateway pendingTaskQueue, and a success-shaped
 * result is returned so core does NOT fall back to LINE. Non-retriable errors throw.
 * @param {string} apiUrl
 * @param {string} paneProject
 * @param {string} body — raw reply text (caption or message), not yet prefixed
 * @returns {Promise<{channel: string, messageId: string, chatId: string, timestamp: number}>}
 */
async function sendDevLanePaneRedirect(apiUrl, paneProject, body) {
  const mode = getSessionMode(paneProject);
  const label = mode ? mode.charAt(0).toUpperCase() + mode.slice(1) : "Unknown";
  const prefixed = `[from:OpenClaw Agent - ${label}] ${body}`;
  const tmuxResult = await clawgateTmuxSend(apiUrl, paneProject, prefixed);
  if (tmuxResult.ok) {
    return {
      channel: "clawgate",
      messageId: tmuxResult.result?.message_id ?? `cg-${Date.now()}`,
      chatId: paneProject,
      timestamp: tmuxResult.result?.timestamp ? Date.parse(tmuxResult.result.timestamp) : Date.now(),
    };
  }
  const code = `${tmuxResult.error?.code ?? ""}`.toLowerCase();
  if (REDIRECT_RETRIABLE_CODES.has(code)) {
    enqueueDevLaneText({ project: paneProject, text: prefixed, mode, traceId: "" });
    return {
      channel: "clawgate",
      messageId: `cg-queued-${Date.now()}`,
      chatId: paneProject,
      timestamp: Date.now(),
    };
  }
  throw new Error(`clawgate tmux send failed: ${tmuxResult.error?.message ?? JSON.stringify(tmuxResult)}`);
}

export const outbound = {
  deliveryMode: "direct",
  chunker: null,
  textChunkLimit: 4000,

  /**
   * @param {object} params
   * @param {string} params.to — conversation_hint (e.g. "Test User")
   * @param {string} params.text
   * @param {string} params.accountId
   * @param {object} params.cfg
   * @returns {Promise<{channel: string, messageId: string, chatId: string, timestamp: number}>}
   */
  sendMedia: async ({ to, text, mediaUrl, accountId, cfg, sessionKey }) => {
    // LINE via ClawGate does not support media — send text fallback
    const account = resolveAccount(cfg, accountId);
    setClawgateAuthToken(account.token || "");
    const caption = text || (mediaUrl ? `[media: ${mediaUrl}]` : "[media]");
    // Dev-lane (autonomous/auto tmux): redirect the caption to the CC session
    // pane, not the user's LINE. observe stays on LINE (SPEC-messaging.md §6).
    const paneProject = devLanePaneProject(sessionKey);
    if (paneProject) {
      return await sendDevLanePaneRedirect(account.apiUrl, paneProject, caption);
    }
    const conversationHint = (to === "default" || to === "LINE" || to.includes(":"))
      ? (account.defaultConversation || to)
      : to;
    const result = await clawgateSend(account.apiUrl, conversationHint, caption);

    if (!result.ok) {
      throw new Error(`clawgate send failed: ${result.error?.message ?? JSON.stringify(result)}`);
    }

    return {
      channel: "clawgate",
      messageId: result.result?.message_id ?? `cg-${Date.now()}`,
      chatId: conversationHint,
      timestamp: result.result?.timestamp ? Date.parse(result.result.timestamp) : Date.now(),
    };
  },

  sendText: async ({ to, text, accountId, cfg, sessionKey }) => {
    const account = resolveAccount(cfg, accountId);
    setClawgateAuthToken(account.token || "");
    // Dev-lane (autonomous/auto tmux): route the reply back to the originating CC
    // session pane via adapter=tmux, NOT the user's LINE. The mode lives in the
    // plugin (sessionModes via shared-state); core only propagates sessionKey.
    // observe stays on LINE (SPEC-messaging.md §6).
    const paneProject = devLanePaneProject(sessionKey);
    if (paneProject) {
      return await sendDevLanePaneRedirect(account.apiUrl, paneProject, text);
    }
    // Account-format targets (e.g. "default", "clawgate:default") -> use defaultConversation
    const conversationHint = (to === "default" || to === "LINE" || to.includes(":"))
      ? (account.defaultConversation || to)
      : to;
    const result = await clawgateSend(account.apiUrl, conversationHint, text);

    if (!result.ok) {
      throw new Error(`clawgate send failed: ${result.error?.message ?? JSON.stringify(result)}`);
    }

    return {
      channel: "clawgate",
      messageId: result.result?.message_id ?? `cg-${Date.now()}`,
      chatId: conversationHint,
      timestamp: result.result?.timestamp ? Date.parse(result.result.timestamp) : Date.now(),
    };
  },
};

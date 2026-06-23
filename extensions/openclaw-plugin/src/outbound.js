/**
 * Outbound adapter — sends AI replies to LINE via ClawGate.
 */

import { resolveAccount } from "./config.js";
import { clawgateSend, clawgateTmuxSend, setClawgateAuthToken } from "./client.js";
import { getSessionMode } from "./shared-state.js";

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
      const tmuxResult = await clawgateTmuxSend(account.apiUrl, paneProject, caption);
      if (!tmuxResult.ok) {
        throw new Error(`clawgate tmux send failed: ${tmuxResult.error?.message ?? JSON.stringify(tmuxResult)}`);
      }
      return {
        channel: "clawgate",
        messageId: tmuxResult.result?.message_id ?? `cg-${Date.now()}`,
        chatId: paneProject,
        timestamp: tmuxResult.result?.timestamp ? Date.parse(tmuxResult.result.timestamp) : Date.now(),
      };
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
      const tmuxResult = await clawgateTmuxSend(account.apiUrl, paneProject, text);
      if (!tmuxResult.ok) {
        throw new Error(`clawgate tmux send failed: ${tmuxResult.error?.message ?? JSON.stringify(tmuxResult)}`);
      }
      return {
        channel: "clawgate",
        messageId: tmuxResult.result?.message_id ?? `cg-${Date.now()}`,
        chatId: paneProject,
        timestamp: tmuxResult.result?.timestamp ? Date.parse(tmuxResult.result.timestamp) : Date.now(),
      };
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

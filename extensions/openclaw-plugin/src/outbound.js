/**
 * Outbound adapter — sends AI replies to LINE via ClawGate.
 */

import { resolveAccount } from "./config.js";
import { clawgateSend } from "./client.js";

export const outbound = {
  deliveryMode: "direct",
  chunker: null,
  textChunkLimit: 4000,

  /**
   * @param {object} params
   * @param {string} params.to — conversation_hint (e.g. "Yuzuru Honda")
   * @param {string} params.text
   * @param {string} params.accountId
   * @param {object} params.cfg
   * @returns {Promise<{channel: string, messageId: string, chatId: string, timestamp: number}>}
   */
  sendText: async ({ to, text, accountId, cfg }) => {
    const account = resolveAccount(cfg, accountId);
    const result = await clawgateSend(account.apiUrl, account.token, to, text);

    if (!result.ok) {
      throw new Error(`clawgate send failed: ${result.error?.message ?? JSON.stringify(result)}`);
    }

    return {
      channel: "clawgate",
      messageId: result.result?.message_id ?? `cg-${Date.now()}`,
      chatId: to,
      timestamp: result.result?.timestamp ? Date.parse(result.result.timestamp) : Date.now(),
    };
  },
};

/**
 * ClawGate directory adapter — resolves targets for `message send --target`.
 *
 * Two-layer design:
 *   Layer 1: defaultConversation from openclaw.json config (always available)
 *   Layer 2: Live conversations from LINE AX tree (available when window is foreground)
 *
 * This ensures target resolution works even when LINE is in the background,
 * because the config-based entry is always present.
 *
 * NOTE: Both listPeers and listGroups return the same entries because
 * OpenClaw's target-resolver calls listGroups by default for undecorated
 * names (e.g. "Test User"). LINE doesn't distinguish peers vs groups
 * at the ClawGate level — all conversations are accessed the same way.
 */

import { resolveAccount } from "./config.js";
import { clawgateConversations, setClawgateAuthToken } from "./client.js";

/**
 * Build directory entries for a ClawGate account.
 * @param {object} cfg - full OpenClaw config
 * @param {string|undefined} accountId
 * @returns {Promise<Array<{kind: string, id: string, name?: string, rank?: number}>>}
 */
async function buildEntries(cfg, accountId) {
  const account = resolveAccount(cfg, accountId ?? "default");
  const entries = [];

  // Layer 1: defaultConversation from config (always available, persisted)
  if (account.defaultConversation) {
    entries.push({
      kind: "user",
      id: account.defaultConversation,
      name: account.defaultConversation,
      rank: 100,
    });
  }

  // Layer 2: Live conversations from LINE (available when window is in foreground)
  try {
    setClawgateAuthToken(account.token || "");
    const res = await clawgateConversations(account.apiUrl);
    if (res.ok && res.result?.conversations) {
      for (const c of res.result.conversations) {
        // Skip duplicate if already added from config
        if (c.name === account.defaultConversation) continue;
        entries.push({ kind: "user", id: c.name, name: c.name });
      }
    }
  } catch {
    // LINE not in foreground or ClawGate not running — config fallback is enough
  }

  return entries;
}

export const directory = {
  listPeers: async ({ cfg, accountId }) => buildEntries(cfg, accountId),
  listGroups: async ({ cfg, accountId }) => buildEntries(cfg, accountId),
};

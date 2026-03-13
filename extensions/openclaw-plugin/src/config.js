/**
 * Config adapter — resolves ClawGate account settings from OpenClaw config.
 *
 * Expected config shape in ~/.openclaw/openclaw.json:
 *   channels.clawgate.<accountId> = {
 *     apiUrl: "http://127.0.0.1:8765"      // required
 *     token: "optional-bearer-token"        // optional (remote mode)
 *     prompts: {                             // optional prompt profile controls
 *       enableValidation: true,
 *       enableRepoLocalOverlay: true,
 *       privateOverlayPath: "~/.clawgate/prompts-private.js"
 *     }
 *     // All below are optional — ClawGate Settings UI manages these via GET /v1/config
 *     // enabled: true,
 *     // pollIntervalMs: 3000,
 *     // defaultConversation: "..."
 *   }
 *
 * No token needed — ClawGate binds to 127.0.0.1 only (no auth required).
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const DEFAULTS = {
  apiUrl: "http://127.0.0.1:8765",
  pollIntervalMs: 1500,
  defaultConversation: "",
};

/**
 * @param {object} cfg — full OpenClaw config
 * @returns {string[]} account IDs
 */
export function listAccountIds(cfg) {
  const section = cfg?.channels?.clawgate;
  if (!section || typeof section !== "object") return [];
  return Object.keys(section).filter((k) => typeof section[k] === "object");
}

/**
 * @param {object} cfg
 * @param {string} accountId
 * @returns {object} resolved account
 */
export function resolveAccount(cfg, accountId) {
  // Fallback to default account when accountId is not provided
  const effectiveId = accountId || defaultAccountId(cfg) || "default";
  const section = cfg?.channels?.clawgate?.[effectiveId] ?? {};
  // Resolve telegramChatId: explicit config > credentials file fallback
  let telegramChatId = section.telegramChatId || "";
  if (!telegramChatId) {
    try {
      const credPath = join(homedir(), ".openclaw", "credentials", "telegram-default-allowFrom.json");
      const cred = JSON.parse(readFileSync(credPath, "utf-8"));
      telegramChatId = String(cred?.allowFrom?.[0] || "");
    } catch {
      // No credentials file — telegramChatId stays empty
    }
  }

  return {
    accountId,
    enabled: section.enabled !== false,
    apiUrl: section.apiUrl || DEFAULTS.apiUrl,
    pollIntervalMs: section.pollIntervalMs || DEFAULTS.pollIntervalMs,
    defaultConversation: section.defaultConversation || DEFAULTS.defaultConversation,
    token: section.token || "",
    lineNotify: section.lineNotify,   // undefined = auto-detect from /v1/config; true/false = override
    messenger: section.messenger || "line",
    telegramBotToken: section.telegramBotToken || cfg?.channels?.telegram?.botToken || "",
    telegramChatId,
    config: section,
  };
}

/**
 * @param {object} cfg
 * @returns {string|undefined}
 */
export function defaultAccountId(cfg) {
  const ids = listAccountIds(cfg);
  return ids.includes("default") ? "default" : ids[0];
}

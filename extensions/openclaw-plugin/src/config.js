/**
 * Config adapter — resolves ClawGate account settings from OpenClaw config.
 *
 * Expected config shape in ~/.openclaw/openclaw.json:
 *   channels.clawgate.<accountId> = {
 *     apiUrl: "http://127.0.0.1:8765"      // required
 *     token: "optional-bearer-token"        // optional (remote mode)
 *     // All below are optional — ClawGate Settings UI manages these via GET /v1/config
 *     // enabled: true,
 *     // pollIntervalMs: 3000,
 *     // defaultConversation: "..."
 *   }
 *
 * No token needed — ClawGate binds to 127.0.0.1 only (no auth required).
 */

const DEFAULTS = {
  apiUrl: "http://127.0.0.1:8765",
  pollIntervalMs: 3000,
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
  const section = cfg?.channels?.clawgate?.[accountId] ?? {};
  return {
    accountId,
    enabled: section.enabled !== false,
    apiUrl: section.apiUrl || DEFAULTS.apiUrl,
    pollIntervalMs: section.pollIntervalMs || DEFAULTS.pollIntervalMs,
    defaultConversation: section.defaultConversation || DEFAULTS.defaultConversation,
    token: section.token || "",
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

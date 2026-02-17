/**
 * ClawGate HTTP client — thin wrapper around the localhost API.
 * Uses Node.js 22+ built-in fetch (no dependencies).
 *
 * Local mode: no authentication required (127.0.0.1 bind).
 * Remote mode: optional Bearer token via setClawgateAuthToken().
 * CSRF protection via Origin header check (server-side).
 */

import { execSync } from "node:child_process";

const DEFAULT_TIMEOUT_MS = 10_000;
let clawgateAuthToken = "";

export function setClawgateAuthToken(token) {
  clawgateAuthToken = (token || "").trim();
}

/**
 * @param {string} apiUrl
 * @param {string} path
 * @param {object} [opts]
 * @param {string} [opts.method]
 * @param {object} [opts.body]
 * @param {string} [opts.traceId]
 * @param {number} [opts.timeoutMs]
 * @returns {Promise<object>}
 */
async function request(apiUrl, path, opts = {}) {
  const { method = "GET", body, traceId = "", timeoutMs = DEFAULT_TIMEOUT_MS } = opts;
  const url = `${apiUrl}${path}`;
  const headers = { "Content-Type": "application/json" };
  if (clawgateAuthToken) {
    headers.Authorization = `Bearer ${clawgateAuthToken}`;
  }
  if (traceId) {
    headers["X-Trace-ID"] = traceId;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const json = await res.json();
    return json;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * GET /v1/health
 * @param {string} apiUrl
 * @returns {Promise<{ok: boolean, version?: string}>}
 */
export async function clawgateHealth(apiUrl) {
  return request(apiUrl, "/v1/health");
}

/**
 * GET /v1/doctor — check ClawGate system status.
 * @param {string} apiUrl
 * @returns {Promise<object>}
 */
export async function clawgateDoctor(apiUrl) {
  return request(apiUrl, "/v1/doctor");
}

/**
 * POST /v1/send — send a message via LINE.
 * @param {string} apiUrl
 * @param {string} conversationHint
 * @param {string} text
 * @returns {Promise<object>}
 */
export async function clawgateSend(apiUrl, conversationHint, text, traceId = "") {
  return request(apiUrl, "/v1/send", {
    method: "POST",
    traceId,
    body: {
      adapter: "line",
      action: "send_message",
      payload: {
        conversation_hint: conversationHint,
        text,
        enter_to_send: true,
        trace_id: traceId || undefined,
      },
    },
  });
}

/**
 * GET /v1/conversations — list LINE conversations visible in AX tree.
 * @param {string} apiUrl
 * @param {number} [limit=50]
 * @returns {Promise<{ok: boolean, result?: {conversations: Array}}>}
 */
export async function clawgateConversations(apiUrl, limit = 50) {
  return request(apiUrl, `/v1/conversations?adapter=line&limit=${limit}`);
}

/**
 * GET /v1/config — get ClawGate configuration.
 * @param {string} apiUrl
 * @returns {Promise<object|null>} config result or null on failure
 */
export async function clawgateConfig(apiUrl) {
  try {
    const res = await request(apiUrl, "/v1/config");
    return res.ok ? res.result : null;
  } catch {
    return null;
  }
}

/**
 * GET /v1/poll?since=N — poll for inbound events.
 * @param {string} apiUrl
 * @param {number} [since=0]
 * @returns {Promise<{ok: boolean, events: Array, next_cursor: number}>}
 */
export async function clawgatePoll(apiUrl, since = 0) {
  const path = since > 0 ? `/v1/poll?since=${since}` : "/v1/poll";
  return request(apiUrl, path);
}

/**
 * POST /v1/send adapter=tmux — send a task to Claude Code via tmux.
 * @param {string} apiUrl
 * @param {string} project — project name (conversation_hint)
 * @param {string} text — the task/prompt to send
 * @returns {Promise<object>}
 */
export async function clawgateTmuxSend(apiUrl, project, text, traceId = "") {
  return request(apiUrl, "/v1/send", {
    method: "POST",
    traceId,
    body: {
      adapter: "tmux",
      action: "send_message",
      payload: {
        conversation_hint: project,
        text,
        enter_to_send: true,
        trace_id: traceId || undefined,
      },
    },
  });
}

/**
 * GET /v1/context?adapter=tmux — get tmux session context.
 * @param {string} apiUrl
 * @returns {Promise<object>}
 */
export async function clawgateTmuxContext(apiUrl) {
  return request(apiUrl, "/v1/context?adapter=tmux");
}

/**
 * GET /v1/conversations?adapter=tmux — list tmux sessions.
 * @param {string} apiUrl
 * @param {number} [limit=50]
 * @returns {Promise<object>}
 */
export async function clawgateTmuxConversations(apiUrl, limit = 50) {
  return request(apiUrl, `/v1/conversations?adapter=tmux&limit=${limit}`);
}

/**
 * GET /v1/messages?adapter=tmux&conversation=PROJECT — read tmux pane content for a specific project.
 * @param {string} apiUrl
 * @param {string} project — project name to read
 * @param {number} [limit=50] — number of lines to capture
 * @param {string} [traceId]
 * @returns {Promise<object>}
 */
export async function clawgateTmuxRead(apiUrl, project, limit = 50, traceId = "") {
  const params = `adapter=tmux&conversation=${encodeURIComponent(project)}&limit=${limit}`;
  return request(apiUrl, `/v1/messages?${params}`, { traceId });
}

/**
 * Resolve the working directory of a tmux pane.
 * @param {string} tmuxTarget — tmux target pane (e.g. "clawgate:0.0")
 * @returns {string|null} — absolute path or null on failure
 */
export function resolveTmuxWorkingDir(tmuxTarget) {
  try {
    return execSync(
      `tmux display-message -p -t "${tmuxTarget}" '#{pane_current_path}'`,
      { encoding: "utf-8", timeout: 3000, stdio: ["pipe", "pipe", "pipe"] }
    ).trim() || null;
  } catch {
    return null;
  }
}

/**
 * ClawGate HTTP client — thin wrapper around the localhost API.
 * Uses Node.js 22+ built-in fetch (no dependencies).
 */

const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * @param {string} apiUrl
 * @param {string} path
 * @param {object} [opts]
 * @param {string} [opts.method]
 * @param {string} [opts.token]
 * @param {object} [opts.body]
 * @param {number} [opts.timeoutMs]
 * @returns {Promise<object>}
 */
async function request(apiUrl, path, opts = {}) {
  const { method = "GET", token, body, timeoutMs = DEFAULT_TIMEOUT_MS } = opts;
  const url = `${apiUrl}${path}`;
  const headers = { "Content-Type": "application/json" };
  if (token) headers["X-Bridge-Token"] = token;

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
 * GET /v1/health — no auth required.
 * @param {string} apiUrl
 * @returns {Promise<{ok: boolean, version?: string}>}
 */
export async function clawgateHealth(apiUrl) {
  return request(apiUrl, "/v1/health");
}

/**
 * Auto-pair: generate code then immediately request token.
 * @param {string} apiUrl
 * @returns {Promise<{token: string}>}
 */
export async function clawgatePair(apiUrl) {
  const gen = await request(apiUrl, "/v1/pair/generate", { method: "POST" });
  if (!gen.ok) throw new Error(`pair/generate failed: ${gen.error?.message ?? JSON.stringify(gen)}`);

  const code = gen.result.code;
  const req = await request(apiUrl, "/v1/pair/request", {
    method: "POST",
    body: { code, client_name: "openclaw-clawgate-plugin" },
  });
  if (!req.ok) throw new Error(`pair/request failed: ${req.error?.message ?? JSON.stringify(req)}`);

  return { token: req.result.token };
}

/**
 * GET /v1/doctor — check ClawGate system status.
 * @param {string} apiUrl
 * @param {string} token
 * @returns {Promise<object>}
 */
export async function clawgateDoctor(apiUrl, token) {
  return request(apiUrl, "/v1/doctor", { token });
}

/**
 * POST /v1/send — send a message via LINE.
 * @param {string} apiUrl
 * @param {string} token
 * @param {string} conversationHint
 * @param {string} text
 * @returns {Promise<object>}
 */
export async function clawgateSend(apiUrl, token, conversationHint, text) {
  return request(apiUrl, "/v1/send", {
    method: "POST",
    token,
    body: {
      adapter: "line",
      action: "send_message",
      payload: {
        conversation_hint: conversationHint,
        text,
        enter_to_send: true,
      },
    },
  });
}

/**
 * GET /v1/poll?since=N — poll for inbound events.
 * @param {string} apiUrl
 * @param {string} token
 * @param {number} [since=0]
 * @returns {Promise<{ok: boolean, events: Array, next_cursor: number}>}
 */
export async function clawgatePoll(apiUrl, token, since = 0) {
  const path = since > 0 ? `/v1/poll?since=${since}` : "/v1/poll";
  return request(apiUrl, path, { token });
}

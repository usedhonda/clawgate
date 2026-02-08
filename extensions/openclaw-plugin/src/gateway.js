/**
 * Gateway adapter — polls ClawGate for inbound LINE messages and dispatches to OpenClaw AI.
 *
 * Flow:
 *   1. Obtain token (from config or auto-pair)
 *   2. Verify ClawGate health via /v1/doctor
 *   3. Poll /v1/poll?since=cursor in a loop
 *   4. For each inbound_message event:
 *      - Build MsgContext
 *      - recordInboundSession()
 *      - createReplyDispatcherWithTyping() → deliver callback sends via ClawGate
 *      - dispatchInboundMessage() → triggers AI reply
 *   5. Repeat until abortSignal fires
 */

import { resolveAccount } from "./config.js";
import {
  clawgateHealth,
  clawgatePair,
  clawgateDoctor,
  clawgateSend,
  clawgatePoll,
} from "./client.js";

/** @type {import("openclaw/plugin-sdk").PluginRuntime | null} */
let _runtime = null;

export function setGatewayRuntime(runtime) {
  _runtime = runtime;
}

function getRuntime() {
  if (!_runtime) throw new Error("clawgate: gateway runtime not initialized");
  return _runtime;
}

// ── Plugin-level echo suppression ──────────────────────────────
// ClawGate's RecentSendTracker uses an 8-second window which is too short
// for AI replies (typically 10-30s). We maintain a secondary tracker here.

const ECHO_WINDOW_MS = 45_000; // 45 seconds — covers AI processing time
const COOLDOWN_MS = 5_000;     // 5 seconds cooldown after each send

/** @type {{ text: string, time: number }[]} */
const recentSends = [];
let lastSendTime = 0;

function recordPluginSend(text) {
  lastSendTime = Date.now();
  recentSends.push({ text: text.trim(), time: Date.now() });
  // Prune old entries
  const cutoff = Date.now() - ECHO_WINDOW_MS;
  while (recentSends.length > 0 && recentSends[0].time < cutoff) {
    recentSends.shift();
  }
}

/**
 * Check if event text looks like an echo of a recently sent message.
 * Uses substring matching since OCR text may be noisy/truncated.
 */
function isPluginEcho(eventText) {
  if (!eventText) return false;
  const now = Date.now();

  // Cooldown: suppress everything within COOLDOWN_MS of last send
  if (now - lastSendTime < COOLDOWN_MS) return true;

  const cutoff = now - ECHO_WINDOW_MS;
  const normalizedEvent = eventText.replace(/\s+/g, " ").trim();

  for (const s of recentSends) {
    if (s.time < cutoff) continue;
    // Check if any significant portion of the sent text appears in the event
    const sentSnippet = s.text.slice(0, 40).replace(/\s+/g, " ");
    if (sentSnippet.length >= 8 && normalizedEvent.includes(sentSnippet)) {
      return true;
    }
  }
  return false;
}

// ── Inbound deduplication ────────────────────────────────────
// ClawGate's InboundWatcher has 3 independent detection sources (AXRow, PixelDiff,
// NotificationBanner) that can emit multiple events for the same message.
// We deduplicate by fingerprint within a sliding time window.

const DEDUP_WINDOW_MS = 15_000; // 15 seconds
const MIN_TEXT_LENGTH = 5;      // Skip empty/short texts (OCR noise, read-receipts)

/** @type {{ fingerprint: string, time: number }[]} */
const recentInbounds = [];

function eventFingerprint(text) {
  return text.replace(/\s+/g, " ").trim().slice(0, 60);
}

function isDuplicateInbound(eventText) {
  const now = Date.now();
  // Prune expired entries
  while (recentInbounds.length > 0 && recentInbounds[0].time < now - DEDUP_WINDOW_MS) {
    recentInbounds.shift();
  }
  const fp = eventFingerprint(eventText);
  if (fp.length < 10) return false; // Too short to compare reliably
  return recentInbounds.some((r) => r.fingerprint === fp);
}

function recordInbound(eventText) {
  recentInbounds.push({ fingerprint: eventFingerprint(eventText), time: Date.now() });
}

/**
 * Sleep that respects abort signal.
 * @param {number} ms
 * @param {AbortSignal} [signal]
 */
function sleep(ms, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
  });
}

// ── Re-pair backoff & circuit breaker ────────────────────────
const REPARE_BACKOFF_INITIAL_MS = 3_000;
const REPARE_BACKOFF_MAX_MS = 60_000;
const REPARE_CIRCUIT_WINDOW_MS = 5 * 60_000; // 5 minutes
const REPARE_CIRCUIT_THRESHOLD = 5;           // max re-pairs in window
const REPARE_CIRCUIT_COOLDOWN_MS = 60_000;    // pause when tripped

/** @type {{ time: number }[]} */
const repairHistory = [];
let repairBackoffMs = REPARE_BACKOFF_INITIAL_MS;
let repairConsecutiveFailures = 0;

/**
 * Check if re-pair circuit breaker is tripped.
 * Returns cooldown ms to wait, or 0 if OK to proceed.
 */
function repairCircuitCheck() {
  const now = Date.now();
  // Prune old entries outside the window
  while (repairHistory.length > 0 && repairHistory[0].time < now - REPARE_CIRCUIT_WINDOW_MS) {
    repairHistory.shift();
  }
  if (repairHistory.length >= REPARE_CIRCUIT_THRESHOLD) {
    return REPARE_CIRCUIT_COOLDOWN_MS;
  }
  return 0;
}

function repairRecordAttempt() {
  repairHistory.push({ time: Date.now() });
}

function repairResetBackoff() {
  repairBackoffMs = REPARE_BACKOFF_INITIAL_MS;
  repairConsecutiveFailures = 0;
}

function repairBumpBackoff() {
  repairConsecutiveFailures++;
  repairBackoffMs = Math.min(repairBackoffMs * 2, REPARE_BACKOFF_MAX_MS);
}

/**
 * Wait for ClawGate API to become reachable.
 * @param {string} apiUrl
 * @param {AbortSignal} [signal]
 * @param {object} [log]
 */
async function waitForReady(apiUrl, signal, log) {
  const maxWait = 60_000;
  const interval = 2_000;
  const start = Date.now();

  while (!signal?.aborted) {
    try {
      const res = await clawgateHealth(apiUrl);
      if (res.ok) return;
    } catch {
      // not reachable yet
    }
    if (Date.now() - start > maxWait) {
      throw new Error(`clawgate: API not reachable after ${maxWait / 1000}s at ${apiUrl}`);
    }
    log?.debug?.(`clawgate: waiting for API at ${apiUrl}...`);
    await sleep(interval, signal);
  }
}

/**
 * Obtain a valid token — use config value or auto-pair.
 * @param {object} account
 * @param {object} [log]
 * @returns {Promise<string>}
 */
async function ensureToken(account, log) {
  if (account.token) return account.token;

  log?.info?.(`clawgate: [${account.accountId}] no token configured, auto-pairing...`);
  const { token } = await clawgatePair(account.apiUrl);
  log?.info?.(`clawgate: [${account.accountId}] paired successfully`);

  // Note: token is NOT saved to config file to avoid overwriting other config sections.
  // The token lives only in memory for this gateway session.
  // On ClawGate restart, the token will be re-paired automatically.

  return token;
}

/**
 * Build MsgContext from a ClawGate poll event.
 * @param {object} event — from /v1/poll
 * @param {string} accountId
 * @param {string} [defaultConversation] — override for conversation name (LINE Qt always reports "LINE")
 * @returns {object} MsgContext-compatible object
 */
function buildMsgContext(event, accountId, defaultConversation) {
  const payload = event.payload ?? {};
  // LINE Qt window title is always "LINE", so use defaultConversation from config
  const rawConv = payload.conversation || "LINE";
  const conversation = (rawConv === "LINE" && defaultConversation) ? defaultConversation : rawConv;
  const sender = payload.sender || conversation;
  const text = payload.text || "";
  const source = payload.source || "poll";
  const timestamp = event.observed_at ? Date.parse(event.observed_at) : Date.now();

  return {
    Body: text,
    RawBody: text,
    CommandBody: text,
    From: `line:${sender}`,
    To: `clawgate:${accountId}`,
    SessionKey: `clawgate:${accountId}:${conversation}`,
    AccountId: accountId,
    ChatType: "direct",
    Provider: "clawgate",
    Surface: "clawgate",
    ConversationLabel: conversation,
    SenderName: sender,
    SenderId: sender,
    MessageSid: String(event.id ?? Date.now()),
    Timestamp: timestamp,
    CommandAuthorized: true,
    OriginatingChannel: "clawgate",
    OriginatingTo: conversation,
    _clawgateSource: source,
  };
}

/**
 * Handle a single inbound message: dispatch to AI, send reply via ClawGate.
 * @param {object} params
 * @param {object} params.event
 * @param {string} params.accountId
 * @param {string} params.apiUrl
 * @param {string} params.token
 * @param {object} params.cfg
 * @param {string} [params.defaultConversation]
 * @param {object} [params.log]
 */
async function handleInboundMessage({ event, accountId, apiUrl, token, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const ctx = buildMsgContext(event, accountId, defaultConversation);
  const conversation = ctx.ConversationLabel;

  log?.info?.(`clawgate: [${accountId}] inbound from "${ctx.SenderName}" in "${conversation}": "${ctx.Body?.slice(0, 80)}"`);

  // Record session
  try {
    const storePath = runtime.config?.storePath ?? "";
    if (storePath && runtime.channel?.session?.recordInboundSession) {
      await runtime.channel.session.recordInboundSession({
        storePath,
        sessionKey: ctx.SessionKey,
        ctx,
        updateLastRoute: {
          sessionKey: ctx.SessionKey,
          channel: "clawgate",
          to: conversation,
          accountId,
        },
        onRecordError: (err) => log?.warn?.(`clawgate: session record error: ${err}`),
      });
    }
  } catch (err) {
    log?.warn?.(`clawgate: recordInboundSession failed: ${err}`);
  }

  // Dispatch to AI using runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher
  // This creates a dispatcher internally and handles the full dispatch flow.
  const deliver = async (payload) => {
    const text = payload.text || payload.body || "";
    if (!text.trim()) return;
    log?.info?.(`clawgate: [${accountId}] sending reply to "${conversation}": "${text.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, token, conversation, text);
      recordPluginSend(text); // Track for echo suppression
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send reply failed: ${err}`);
    }
  };

  try {
    const dispatch = runtime.channel?.reply?.dispatchReplyWithBufferedBlockDispatcher;
    if (dispatch) {
      await dispatch({
        ctx,
        cfg,
        dispatcherOptions: {
          deliver,
          humanDelay: { mode: "off" },
          onError: (err) => log?.error?.(`clawgate: dispatch error: ${err}`),
        },
      });
    } else {
      log?.error?.("clawgate: dispatchReplyWithBufferedBlockDispatcher not found on runtime");
    }
  } catch (err) {
    log?.error?.(`clawgate: [${accountId}] dispatch failed: ${err}`);
  }
}

/**
 * Gateway startAccount — called by OpenClaw to begin monitoring.
 * Returns a Promise that resolves when abortSignal fires.
 *
 * @param {object} ctx — ChannelGatewayContext
 * @returns {Promise<void>}
 */
export async function startAccount(ctx) {
  const { cfg, account, abortSignal, log } = ctx;
  const accountId = account.accountId;
  const apiUrl = account.apiUrl;
  const pollIntervalMs = account.pollIntervalMs || 3000;
  const defaultConversation = account.defaultConversation || "";

  log?.info?.(`clawgate: [${accountId}] starting gateway (apiUrl=${apiUrl}, poll=${pollIntervalMs}ms, defaultConv="${defaultConversation}")`);

  // Wait for ClawGate to be reachable
  await waitForReady(apiUrl, abortSignal, log);
  if (abortSignal?.aborted) return;

  // Ensure we have a token
  let token;
  try {
    token = await ensureToken(account, log);
  } catch (err) {
    log?.error?.(`clawgate: [${accountId}] failed to obtain token: ${err}`);
    throw err;
  }

  // Verify system health
  try {
    const doctor = await clawgateDoctor(apiUrl, token);
    if (doctor.ok) {
      log?.info?.(`clawgate: [${accountId}] doctor OK (${doctor.summary?.passed}/${doctor.summary?.total} checks passed)`);
    } else {
      log?.warn?.(`clawgate: [${accountId}] doctor reported issues: ${JSON.stringify(doctor.summary)}`);
    }
  } catch (err) {
    log?.warn?.(`clawgate: [${accountId}] doctor check failed: ${err}`);
  }

  // Get initial cursor
  let cursor = 0;
  try {
    const initial = await clawgatePoll(apiUrl, token, 0);
    if (initial.ok) {
      cursor = initial.next_cursor ?? 0;
      log?.info?.(`clawgate: [${accountId}] initial cursor=${cursor}, skipping ${initial.events?.length ?? 0} existing events`);
    }
  } catch (err) {
    log?.warn?.(`clawgate: [${accountId}] initial poll failed: ${err}`);
  }

  // Polling loop
  while (!abortSignal?.aborted) {
    try {
      const poll = await clawgatePoll(apiUrl, token, cursor);

      if (poll.ok && poll.events?.length > 0) {
        for (const event of poll.events) {
          if (abortSignal?.aborted) break;

          // Only process inbound_message events (skip echo_message, heartbeat, etc.)
          if (event.type !== "inbound_message") continue;

          const eventText = event.payload?.text || "";

          // ② Skip empty/short texts (OCR noise, read-receipts, scroll artifacts)
          if (eventText.trim().length < MIN_TEXT_LENGTH) {
            log?.debug?.(`clawgate: [${accountId}] skipped short text (${eventText.length} chars)`);
            continue;
          }

          // ③ Plugin-level echo suppression (ClawGate's 8s window is too short for AI replies)
          if (isPluginEcho(eventText)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed echo: "${eventText.slice(0, 60)}"`);
            continue;
          }

          // ④ Cross-source deduplication (AXRow / PixelDiff / NotificationBanner)
          if (isDuplicateInbound(eventText)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed duplicate: "${eventText.slice(0, 60)}"`);
            continue;
          }

          // ⑤ Record before dispatch so subsequent duplicates are caught
          recordInbound(eventText);

          try {
            await handleInboundMessage({
              event,
              accountId,
              apiUrl,
              token,
              cfg,
              defaultConversation,
              log,
            });
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] handleInboundMessage failed: ${err}`);
          }
        }
        cursor = poll.next_cursor ?? cursor;
      } else if (!poll.ok && poll.error?.code === "unauthorized") {
        // Token expired — re-pair with backoff & circuit breaker
        const cooldown = repairCircuitCheck();
        if (cooldown > 0) {
          log?.warn?.(`clawgate: [${accountId}] re-pair circuit breaker tripped (${repairHistory.length} attempts in 5min), cooling down ${cooldown / 1000}s`);
          await sleep(cooldown, abortSignal);
          if (abortSignal?.aborted) break;
          continue;
        }

        log?.warn?.(`clawgate: [${accountId}] token expired, re-pairing (backoff=${repairBackoffMs}ms, attempt=${repairConsecutiveFailures + 1})...`);
        repairRecordAttempt();

        try {
          const { token: newToken } = await clawgatePair(apiUrl);
          token = newToken;
          account.token = newToken;
          repairResetBackoff();
          log?.info?.(`clawgate: [${accountId}] re-paired successfully`);
        } catch (pairErr) {
          repairBumpBackoff();
          log?.error?.(`clawgate: [${accountId}] re-pair failed (next backoff=${repairBackoffMs}ms): ${pairErr}`);
          await sleep(repairBackoffMs, abortSignal);
          if (abortSignal?.aborted) break;
        }
      }
    } catch (err) {
      if (abortSignal?.aborted) break;
      log?.error?.(`clawgate: [${accountId}] poll error: ${err}`);
    }

    await sleep(pollIntervalMs, abortSignal);
  }

  log?.info?.(`clawgate: [${accountId}] gateway stopped`);
}

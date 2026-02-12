/**
 * Gateway adapter — polls ClawGate for inbound LINE messages and dispatches to OpenClaw AI.
 *
 * Flow:
 *   1. Wait for ClawGate health
 *   2. Verify system status via /v1/doctor
 *   3. Poll /v1/poll?since=cursor in a loop
 *   4. For each inbound_message event:
 *      - Build MsgContext
 *      - recordInboundSession()
 *      - createReplyDispatcherWithTyping() -> deliver callback sends via ClawGate
 *      - dispatchInboundMessage() -> triggers AI reply
 *   5. Repeat until abortSignal fires
 */

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveAccount } from "./config.js";
import {
  clawgateHealth,
  clawgateDoctor,
  clawgateConfig,
  clawgateSend,
  clawgatePoll,
  clawgateTmuxSend,
  setClawgateAuthToken,
} from "./client.js";
import {
  getProjectContext,
  getProjectRoster,
  getStableContext,
  getDynamicEnvelope,
  markContextSent,
  invalidateProject,
  registerProjectPath,
  resolveProjectPath,
  setProgressSnapshot,
} from "./context-cache.js";

/** @type {import("openclaw/plugin-sdk").PluginRuntime | null} */
let _runtime = null;

export function setGatewayRuntime(runtime) {
  _runtime = runtime;
}

function getRuntime() {
  if (!_runtime) throw new Error("clawgate: gateway runtime not initialized");
  return _runtime;
}

// ── Claude Code knowledge (static, loaded once) ─────────────────
let _ccKnowledge = "";
try {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  _ccKnowledge = readFileSync(join(__dirname, "..", "claude-code-knowledge.md"), "utf-8");
} catch {
  // Not critical — knowledge file missing just means less context
}

// ── Session state tracking (for roster) ──────────────────────────
/** @type {Map<string, string>} project -> mode */
const sessionModes = new Map();
/** @type {Map<string, string>} project -> status */
const sessionStatuses = new Map();

// ── Progress dispatch throttle ──────────────────────────────────
// Limit how often progress events are forwarded to the AI (to avoid noise)
const PROGRESS_DISPATCH_INTERVAL_MS = 60_000; // 60 seconds minimum between dispatches
/** @type {Map<string, number>} project -> last dispatch timestamp */
const lastProgressDispatch = new Map();

function shouldDispatchProgress(project) {
  const now = Date.now();
  const last = lastProgressDispatch.get(project) || 0;
  if (now - last >= PROGRESS_DISPATCH_INTERVAL_MS) {
    lastProgressDispatch.set(project, now);
    return true;
  }
  return false;
}

function eventTimestamp(event) {
  const raw = event?.observed_at ?? event?.observedAt;
  if (!raw) return Date.now();
  const parsed = Date.parse(raw);
  return Number.isNaN(parsed) ? Date.now() : parsed;
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

const DEDUP_WINDOW_MS = 0; // disable duplicate suppression (recall-first)
const MIN_TEXT_LENGTH = 1;      // Favor recall over precision for OCR-driven ingress
const STALE_REPEAT_WINDOW_MS = 0; // disable stale-repeat suppression (recall-first)

/** @type {{ fingerprint: string, time: number }[]} */
const recentInbounds = [];
/** @type {{ key: string, time: number }[]} */
const recentStableInbounds = [];

function eventFingerprint(text) {
  return text.replace(/\s+/g, " ").trim().slice(0, 60);
}

function isDuplicateInbound(eventText) {
  if (DEDUP_WINDOW_MS <= 0) return false;
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

function stableKey(eventText, conversation) {
  const normalizedText = eventText.replace(/\s+/g, " ").trim().toLowerCase();
  const normalizedConv = (conversation || "").replace(/\s+/g, " ").trim().toLowerCase();
  return `${normalizedConv}::${normalizedText}`;
}

function isStaleRepeatInbound(eventText, conversation, source) {
  if (STALE_REPEAT_WINDOW_MS <= 0) return false;
  // Notification banner is explicit new-message signal; don't block it.
  if (source === "notification_banner") return false;

  const now = Date.now();
  while (recentStableInbounds.length > 0 && recentStableInbounds[0].time < now - STALE_REPEAT_WINDOW_MS) {
    recentStableInbounds.shift();
  }
  const key = stableKey(eventText, conversation);
  if (key.length < 12) return false;
  return recentStableInbounds.some((r) => r.key === key);
}

function recordStableInbound(eventText, conversation) {
  recentStableInbounds.push({ key: stableKey(eventText, conversation), time: Date.now() });
}

function isUiChromeLine(line) {
  const s = line.trim();
  if (!s) return true;
  if (/^既読$/.test(s)) return true;
  if (/^未読$/.test(s)) return true;
  if (/^ここから未読メッセージ$/.test(s)) return true;
  if (/^LINE$/.test(s)) return true;
  if (/^Test User\b/.test(s)) return true;
  if (/^(午前|午後)\s*\d{1,2}:\d{2}$/.test(s)) return true;
  if (/^\d{1,2}:\d{2}$/.test(s)) return true;
  if (/^\d+$/.test(s)) return true;
  // Treat only punctuation/symbol-only tokens as noise.
  // NOTE: Do not use \W here; in JS it classifies Japanese text as non-word.
  if (/^[\p{P}\p{S}\s_]+$/u.test(s)) return true;
  return false;
}

function normalizeInboundText(rawText, source) {
  const text = (rawText || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  if (!text) return "";

  // Notification banner is already structured enough; keep as-is.
  if (source === "notification_banner") {
    return text;
  }

  let lines = text
    .split("\n")
    .map((l) => l.replace(/\s+/g, " ").trim())
    .filter((l) => l.length > 0)
    .filter((l) => !isUiChromeLine(l));

  // Re-join OCR wrap fragments so one user message is not split into many pieces.
  lines = mergeWrappedLines(lines);

  // Fallback: if chrome filtering removed everything, keep the last raw non-empty line.
  // This avoids dropping valid short test messages mixed with noisy OCR blocks.
  if (lines.length === 0) {
    const rawLines = text
      .split("\n")
      .map((l) => l.replace(/\s+/g, " ").trim())
      .filter((l) => l.length > 0);
    if (rawLines.length > 0) {
      lines = [rawLines[rawLines.length - 1]];
    }
  }

  // Keep raw order as much as possible (do not dedupe/slice). Let the AI decide.

  return lines.join("\n").trim();
}

function mergeWrappedLines(lines) {
  if (!Array.isArray(lines) || lines.length <= 1) return lines || [];
  const merged = [];

  const shouldAppend = (prev, next) => {
    if (!prev || !next) return false;
    if (isUiChromeLine(prev) || isUiChromeLine(next)) return false;
    // If previous line already ends with sentence punctuation, keep boundary.
    if (/[。！？!?]$/.test(prev)) return false;
    // OCR wraps often produce short tail/head fragments.
    if (prev.length <= 36 || next.length <= 20) return true;
    // Japanese line wraps in LINE often break without punctuation.
    if (!/[、。！？!?]$/.test(prev) && /^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}A-Za-z0-9]/u.test(next)) {
      return true;
    }
    return false;
  };

  for (const line of lines) {
    if (merged.length === 0) {
      merged.push(line);
      continue;
    }
    const prev = merged[merged.length - 1];
    if (shouldAppend(prev, line)) {
      merged[merged.length - 1] = `${prev}${line}`;
    } else {
      merged.push(line);
    }
  }
  return merged;
}

// ── Pending questions tracking ────────────────────────────────
// Tracks AskUserQuestion menus displayed in Claude Code sessions.
// Used by roster and answer routing.

/** @type {Map<string, { questionText: string, questionId: string, options: string[], selectedIndex: number }>} */
const pendingQuestions = new Map();

function makeTraceId(prefix, event) {
  const existing = event?.payload?.trace_id;
  if (existing) return existing;
  const id = event?.id || Date.now();
  return `${prefix}-${id}`;
}

function traceLog(log, level, fields) {
  const payload = {
    ts: new Date().toISOString(),
    ...fields,
  };
  const line = `clawgate_trace ${JSON.stringify(payload)}`;
  if (level === "error") log?.error?.(line);
  else if (level === "warn") log?.warn?.(line);
  else if (level === "debug") log?.debug?.(line);
  else log?.info?.(line);
}

function pickFirstNonEmptyText(value, depth = 0) {
  if (depth > 4 || value == null) return "";
  if (typeof value === "string") return value.trim();
  if (Array.isArray(value)) {
    for (const item of value) {
      const text = pickFirstNonEmptyText(item, depth + 1);
      if (text) return text;
    }
    return "";
  }
  if (typeof value === "object") {
    const preferredKeys = [
      "text",
      "body",
      "content",
      "message",
      "output",
      "response",
      "final",
      "value",
    ];
    for (const key of preferredKeys) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        const text = pickFirstNonEmptyText(value[key], depth + 1);
        if (text) return text;
      }
    }
    for (const nested of Object.values(value)) {
      const text = pickFirstNonEmptyText(nested, depth + 1);
      if (text) return text;
    }
  }
  return "";
}

function extractReplyText(replyPayload, log, context = "reply") {
  const directText = `${replyPayload?.text ?? ""}`.trim();
  if (directText) return directText;

  const directBody = `${replyPayload?.body ?? ""}`.trim();
  if (directBody) return directBody;

  const deep = pickFirstNonEmptyText(replyPayload);
  if (deep) {
    log?.debug?.(`clawgate: extracted ${context} text via deep payload traversal`);
    return deep;
  }

  const keys = replyPayload && typeof replyPayload === "object"
    ? Object.keys(replyPayload).slice(0, 10).join(",")
    : typeof replyPayload;
  log?.warn?.(`clawgate: empty ${context} text (payload keys/type=${keys || "none"})`);
  return "";
}

function normalizeLineReplyText(text, { project = "", eventKind = "reply" } = {}) {
  const trimmed = `${text || ""}`.replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  if (!trimmed) return "";

  let result = trimmed
    .replace(/\n{3,}/g, "\n\n")
    .replace(/\s+\n/g, "\n")
    .trim();

  // Keep a compact prefix for tmux-origin messages so users can distinguish
  // CC updates from normal LINE conversations at a glance.
  if (project && !/^\[(CC|Claude Code)\b/.test(result)) {
    const kind = eventKind.toUpperCase();
    result = `[CC ${kind} ${project}] ${result}`;
  }

  return result;
}

function buildPairingGuidance({ project = "", mode = "", eventKind = "" } = {}) {
  const proj = project || "current";
  const m = mode || "observe";
  const k = eventKind || "update";
  const header = `[Pairing Guidance] [CC ${proj}] Mode: ${m} | Event: ${k}`;
  return [
    header,
    "Think as a practical pair programmer:",
    "1) Summarize what changed and why it matters.",
    "2) Call out one concrete risk or missing check if any.",
    "3) Give next action in one short step (no long boilerplate).",
    "4) If confidence is low, say what signal/log is missing.",
  ].join("\n");
}

// ── Autonomous task chaining ──────────────────────────────────

/**
 * Extract <cc_task> from AI reply and send to Claude Code via tmux.
 * Returns null if no task tag found.
 * @param {object} params
 * @param {string} params.replyText — full AI reply text
 * @param {string} params.project — target tmux project
 * @param {string} params.apiUrl
 * @param {object} [params.log]
 * @returns {Promise<{lineText: string, taskText: string} | {error: Error, lineText: string} | null>}
 */
async function tryExtractAndSendTask({ replyText, project, apiUrl, traceId, log }) {
  const taskMatch = replyText.match(/<cc_task>([\s\S]*?)<\/cc_task>/);
  if (!taskMatch) return null;

  const taskText = taskMatch[1].trim();
  if (!taskText) return null;

  const lineText = replyText.replace(/<cc_task>[\s\S]*?<\/cc_task>/, "").trim();

  // Prefix task with [OpenClaw Agent] so CC knows the origin
  const prefixedTask = `[OpenClaw Agent] ${taskText}`;

  try {
    const result = await clawgateTmuxSend(apiUrl, project, prefixedTask, traceId);
    if (result?.ok) {
      log?.info?.(`clawgate: task sent to CC (${project}): "${taskText.slice(0, 80)}"`);
      return { lineText, taskText };
    } else {
      const errMsg = result?.error || "unknown error";
      log?.error?.(`clawgate: failed to send task to CC (${project}): ${errMsg}`);
      return { error: new Error(errMsg), lineText: replyText };
    }
  } catch (err) {
    log?.error?.(`clawgate: failed to send task to CC (${project}): ${err}`);
    return { error: err, lineText: replyText };
  }
}

/**
 * Extract <cc_answer> from AI reply and send menu selection to Claude Code.
 * Returns null if no answer tag found.
 * @param {object} params
 * @param {string} params.replyText — full AI reply text
 * @param {string} params.apiUrl
 * @param {object} [params.log]
 * @returns {Promise<{lineText: string, answerIndex: number} | {error: Error, lineText: string} | null>}
 */
async function tryExtractAndSendAnswer({ replyText, apiUrl, traceId, log }) {
  const answerMatch = replyText.match(/<cc_answer\s+project="([^"]+)">([\s\S]*?)<\/cc_answer>/);
  if (!answerMatch) return null;

  const project = answerMatch[1].trim();
  const answerBody = answerMatch[2].trim();

  // Parse answer index — expect a number (0-based or 1-based)
  const answerIndex = parseInt(answerBody, 10);
  if (isNaN(answerIndex)) {
    log?.warn?.(`clawgate: cc_answer index is not a number: "${answerBody}"`);
    return null;
  }

  // Convert to 0-based if user sends 1-based
  const zeroBasedIndex = answerIndex >= 1 ? answerIndex - 1 : answerIndex;

  const lineText = replyText.replace(/<cc_answer\s+project="[^"]*">[\s\S]*?<\/cc_answer>/, "").trim();

  // Verify the question is still pending
  const pending = pendingQuestions.get(project);
  if (!pending) {
    log?.warn?.(`clawgate: no pending question for project "${project}", answer may be stale`);
  }

  const selectCmd = `__cc_select:${zeroBasedIndex}`;

  try {
    const result = await clawgateTmuxSend(apiUrl, project, selectCmd, traceId);
    if (result?.ok) {
      log?.info?.(`clawgate: answer sent to CC (${project}): option ${zeroBasedIndex}`);
      pendingQuestions.delete(project);
      return { lineText, answerIndex: zeroBasedIndex };
    } else {
      const errMsg = result?.error || "unknown error";
      log?.error?.(`clawgate: failed to send answer to CC (${project}): ${errMsg}`);
      return { error: new Error(errMsg), lineText: replyText };
    }
  } catch (err) {
    log?.error?.(`clawgate: failed to send answer to CC (${project}): ${err}`);
    return { error: err, lineText: replyText };
  }
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
 * Build a location prefix string from vibeterm telemetry data.
 * Returns empty string if no recent location is available.
 */
function buildLocationPrefix() {
  const loc = globalThis.__vibetermLatestLocation;
  if (!loc || typeof loc.lat !== "number" || typeof loc.lon !== "number") return "";

  const ageMs = Date.now() - (loc.receivedAt ? Date.parse(loc.receivedAt) : Date.now());
  const ageMins = Math.round(ageMs / 60_000);
  if (ageMins > 1440) return ""; // Discard data older than 24 hours

  const parts = [`${loc.lat.toFixed(4)}, ${loc.lon.toFixed(4)}`];
  if (typeof loc.accuracy === "number") parts.push(`accuracy ${Math.round(loc.accuracy)}m`);
  if (ageMins <= 1) parts.push("just now");
  else if (ageMins < 60) parts.push(`${ageMins} min ago`);
  else parts.push(`${Math.round(ageMins / 60)}h ago`);

  return `[User location: ${parts.join(", ")}]`;
}

/**
 * Build a compact roster of active Claude Code projects for LINE messages.
 * @returns {string}
 */
function buildRosterPrefix() {
  const roster = getProjectRoster(sessionModes, sessionStatuses, pendingQuestions);
  if (!roster) return "";

  // Check if any project is in autonomous mode
  const hasTaskCapable = [...sessionModes.values()].some((m) => m === "autonomous");
  const taskHint = hasTaskCapable
    ? `\nYou can send tasks to autonomous projects by including <cc_task>your task</cc_task> in your reply. Text outside the tags goes to LINE.`
    : "";

  // Check for pending questions
  const hasQuestions = pendingQuestions.size > 0;
  const answerHint = hasQuestions
    ? `\nTo answer a pending question, include <cc_answer project="name">{option number}</cc_answer> in your reply.`
    : "";

  const sessionCount = sessionModes.size;
  return `[Active Claude Code Projects: ${sessionCount} session${sessionCount !== 1 ? "s" : ""}]\n${roster}${taskHint}${answerHint}`;
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
  const timestamp = eventTimestamp(event);

  const ctx = {
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

  // Build BodyForAgent with location + project roster prefixes
  const locationPrefix = buildLocationPrefix();
  const rosterPrefix = buildRosterPrefix();
  const prefixes = [locationPrefix, rosterPrefix].filter(Boolean);
  if (prefixes.length > 0) {
    ctx.BodyForAgent = `${prefixes.join("\n\n")}\n\n${text}`;
  }

  return ctx;
}

/**
 * Handle a single inbound message: dispatch to AI, send reply via ClawGate.
 * @param {object} params
 * @param {object} params.event
 * @param {string} params.accountId
 * @param {string} params.apiUrl
 * @param {object} params.cfg
 * @param {string} [params.defaultConversation]
 * @param {object} [params.log]
 */
async function handleInboundMessage({ event, accountId, apiUrl, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const traceId = makeTraceId("line", event);
  if (!event.payload) event.payload = {};
  event.payload.trace_id = traceId;
  const ctx = buildMsgContext(event, accountId, defaultConversation);
  const conversation = ctx.ConversationLabel;
  traceLog(log, "info", {
    trace_id: traceId,
    stage: "gateway_inbound_received",
    action: "dispatch_inbound_message",
    status: "start",
    source: event.payload?.source || "poll",
    adapter: event.adapter || "line",
  });

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

  // Find task-capable projects (autonomous or auto) for potential task routing from LINE replies
  const taskCapableProjects = [...sessionModes.entries()]
    .filter(([, m]) => m === "autonomous")
    .map(([p]) => p);

  // Dispatch to AI using runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher
  const deliver = async (payload) => {
    const text = extractReplyText(payload, log, "line_inbound_dispatch");
    if (!text.trim()) return;

    // Try to extract <cc_answer> first (from AI reply to question)
    const answerResult = await tryExtractAndSendAnswer({ replyText: text, apiUrl, traceId, log });
    if (answerResult) {
      if (answerResult.error) {
        const msg = `[Answer send failed: ${answerResult.error.message || answerResult.error}]\n\n${answerResult.lineText}`;
        try { await clawgateSend(apiUrl, conversation, msg, traceId); recordPluginSend(msg); } catch {}
      } else if (answerResult.lineText) {
        try { await clawgateSend(apiUrl, conversation, answerResult.lineText, traceId); recordPluginSend(answerResult.lineText); } catch {}
      }
      return;
    }

    // If there are task-capable projects, try to extract <cc_task> from AI reply
    if (taskCapableProjects.length > 0) {
      const result = await tryExtractAndSendTask({
        replyText: text, project: taskCapableProjects[0], apiUrl, traceId, log,
      });
      if (result) {
        if (result.error) {
          const msg = `[Task send failed: ${result.error.message || result.error}]\n\n${result.lineText}`;
          try {
            await clawgateSend(apiUrl, conversation, msg, traceId);
            recordPluginSend(msg);
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
          }
        } else if (result.lineText) {
          try {
            await clawgateSend(apiUrl, conversation, result.lineText, traceId);
            recordPluginSend(result.lineText);
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send line reply failed: ${err}`);
          }
        }
        return;
      }
    }

    const lineText = normalizeLineReplyText(text);
    log?.info?.(`clawgate: [${accountId}] sending reply to "${conversation}": "${lineText.slice(0, 80)}"`);
    traceLog(log, "info", {
      trace_id: traceId,
      stage: "gateway_forward_start",
      action: "line_send",
      status: "start",
      conversation,
    });
    try {
      await clawgateSend(apiUrl, conversation, lineText, traceId);
      recordPluginSend(lineText); // Track for echo suppression
      traceLog(log, "info", {
        trace_id: traceId,
        stage: "gateway_forward_ok",
        action: "line_send",
        status: "ok",
        conversation,
      });
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send reply failed: ${err}`);
      traceLog(log, "error", {
        trace_id: traceId,
        stage: "gateway_forward_failed",
        action: "line_send",
        status: "failed",
        conversation,
        error: String(err),
      });
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
      traceLog(log, "info", {
        trace_id: traceId,
        stage: "gateway_dispatch_done",
        action: "dispatch_inbound_message",
        status: "ok",
      });
    } else {
      log?.error?.("clawgate: dispatchReplyWithBufferedBlockDispatcher not found on runtime");
    }
  } catch (err) {
    log?.error?.(`clawgate: [${accountId}] dispatch failed: ${err}`);
    traceLog(log, "error", {
      trace_id: traceId,
      stage: "gateway_dispatch_failed",
      action: "dispatch_inbound_message",
      status: "failed",
      error: String(err),
    });
  }
}

/**
 * Handle a tmux question event: Claude Code is displaying an AskUserQuestion menu.
 * Dispatches the question + options to AI, which can answer via <cc_answer>.
 * @param {object} params
 */
async function handleTmuxQuestion({ event, accountId, apiUrl, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const traceId = makeTraceId("tmux-question", event);
  const payload = event.payload ?? {};
  payload.trace_id = traceId;
  const project = payload.project || payload.conversation || "unknown";
  const questionText = payload.question_text || payload.text || "(no question)";
  const optionsRaw = payload.question_options || "";
  const selectedIndex = parseInt(payload.question_selected || "0", 10);
  const questionId = payload.question_id || String(Date.now());
  const mode = payload.mode || sessionModes.get(project) || "observe";
  const tmuxTarget = payload.tmux_target || "";

  // Track session state
  sessionModes.set(project, mode);
  sessionStatuses.set(project, "waiting_input");

  // Track pending question
  const options = optionsRaw.split("\n").filter(Boolean);
  pendingQuestions.set(project, { questionText, questionId, options, selectedIndex });

  if (tmuxTarget) resolveProjectPath(project, tmuxTarget);

  // Format numbered options for Chi
  const numberedOptions = options.map((opt, i) => {
    const marker = i === selectedIndex ? ">>>" : "   ";
    return `${marker} ${i + 1}. ${opt}`;
  }).join("\n");

  const body = `[CC ${project}] Claude Code is asking a question:\n\n${questionText}\n\nOptions:\n${numberedOptions}\n\n[To answer, include <cc_answer project="${project}">{option number}</cc_answer> in your reply. Use 1-based numbering (1 = first option). Text outside the tag goes to LINE.]`;
  const guidedBody = `${buildPairingGuidance({ project, mode, eventKind: "question" })}\n\n---\n\n${body}`;

  const ctx = {
    Body: guidedBody,
    RawBody: guidedBody,
    CommandBody: guidedBody,
    From: `tmux:${project}`,
    To: `clawgate:${accountId}`,
    SessionKey: `clawgate:${accountId}:tmux:${project}`,
    AccountId: accountId,
    ChatType: "direct",
    Provider: "clawgate",
    Surface: "clawgate",
    ConversationLabel: defaultConversation || project,
    SenderName: `Claude Code (${project})`,
    SenderId: `tmux:${project}`,
    MessageSid: String(event.id ?? Date.now()),
    Timestamp: eventTimestamp(event),
    CommandAuthorized: true,
    OriginatingChannel: "clawgate",
    OriginatingTo: defaultConversation || project,
    _clawgateSource: "tmux_question",
    _tmuxMode: mode,
  };

  log?.info?.(`clawgate: [${accountId}] tmux question from "${project}": "${questionText.slice(0, 80)}" (${options.length} options)`);

  // Deliver reply — parse <cc_answer> and route answer, or forward to LINE
  const deliver = async (replyPayload) => {
    const replyText = extractReplyText(replyPayload, log, "tmux_question");
    if (!replyText.trim()) return;

    // Try to extract <cc_answer> first
    const answerResult = await tryExtractAndSendAnswer({ replyText, apiUrl, traceId, log });
    if (answerResult) {
      if (answerResult.error) {
        const msg = `[Answer send failed: ${answerResult.error.message || answerResult.error}]\n\n${answerResult.lineText}`;
        try {
          await clawgateSend(apiUrl, defaultConversation || project, msg, traceId);
          recordPluginSend(msg);
        } catch (err) {
          log?.error?.(`clawgate: [${accountId}] send answer error notice to LINE failed: ${err}`);
        }
      } else if (answerResult.lineText) {
        try {
          await clawgateSend(apiUrl, defaultConversation || project, answerResult.lineText, traceId);
          recordPluginSend(answerResult.lineText);
        } catch (err) {
          log?.error?.(`clawgate: [${accountId}] send answer line text to LINE failed: ${err}`);
        }
      }
      return;
    }

    // No <cc_answer> — try <cc_task> fallback (autonomous mode)
    if (mode === "autonomous") {
      const taskResult = await tryExtractAndSendTask({ replyText, project, apiUrl, traceId, log });
      if (taskResult) {
        if (taskResult.error) {
          const msg = `[Task send failed: ${taskResult.error.message || taskResult.error}]\n\n${taskResult.lineText}`;
          try { await clawgateSend(apiUrl, defaultConversation || project, msg, traceId); recordPluginSend(msg); } catch {}
        } else if (taskResult.lineText) {
          try { await clawgateSend(apiUrl, defaultConversation || project, taskResult.lineText, traceId); recordPluginSend(taskResult.lineText); } catch {}
        }
        return;
      }
    }

    // Default: forward to LINE
    const lineText = normalizeLineReplyText(replyText, { project, eventKind: "question" });
    log?.info?.(`clawgate: [${accountId}] sending question reply to LINE: "${lineText.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, defaultConversation || project, lineText, traceId);
      recordPluginSend(lineText);
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send question reply to LINE failed: ${err}`);
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
          onError: (err) => log?.error?.(`clawgate: question dispatch error: ${err}`),
        },
      });
    } else {
      log?.error?.("clawgate: dispatchReplyWithBufferedBlockDispatcher not found on runtime");
    }
  } catch (err) {
    log?.error?.(`clawgate: [${accountId}] question dispatch failed: ${err}`);
  }
}

/**
 * Handle a tmux progress event: Claude Code is running and produced new output.
 * Dispatches a progress update to AI (throttled, read-only — no task sending).
 * @param {object} params
 */
async function handleTmuxProgress({ event, accountId, apiUrl, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const traceId = makeTraceId("tmux-progress", event);
  const payload = event.payload ?? {};
  payload.trace_id = traceId;
  const project = payload.project || "unknown";
  const text = payload.text || "(no output)";
  const mode = payload.mode || sessionModes.get(project) || "observe";
  const tmuxTarget = payload.tmux_target || "";

  if (tmuxTarget) resolveProjectPath(project, tmuxTarget);

  const Mode = mode.charAt(0).toUpperCase() + mode.slice(1);
  const baseBody = `[CC ${project}] [${Mode}] [PROGRESS UPDATE]\n\nClaude Code is currently running. Latest output:\n\n${text}`;
  const body = `${buildPairingGuidance({ project, mode, eventKind: "progress" })}\n\n---\n\n${baseBody}`;

  const ctx = {
    Body: body,
    RawBody: body,
    CommandBody: body,
    From: `tmux:${project}`,
    To: `clawgate:${accountId}`,
    SessionKey: `clawgate:${accountId}:tmux:${project}`,
    AccountId: accountId,
    ChatType: "direct",
    Provider: "clawgate",
    Surface: "clawgate",
    ConversationLabel: defaultConversation || project,
    SenderName: `Claude Code (${project})`,
    SenderId: `tmux:${project}`,
    MessageSid: String(event.id ?? Date.now()),
    Timestamp: eventTimestamp(event),
    CommandAuthorized: true,
    OriginatingChannel: "clawgate",
    OriginatingTo: defaultConversation || project,
    _clawgateSource: "tmux_progress",
    _tmuxMode: mode,
  };

  log?.info?.(`clawgate: [${accountId}] tmux progress from "${project}" (mode=${mode}): "${text.slice(0, 80)}"`);

  // Progress updates are read-only — no task sending, just forward to LINE
  const deliver = async (replyPayload) => {
    const replyText = extractReplyText(replyPayload, log, "tmux_progress");
    if (!replyText.trim()) return;

    const lineText = normalizeLineReplyText(replyText, { project, eventKind: "progress" });
    log?.info?.(`clawgate: [${accountId}] sending progress reply to LINE: "${lineText.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, defaultConversation || project, lineText, traceId);
      recordPluginSend(lineText);
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send progress reply to LINE failed: ${err}`);
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
          onError: (err) => log?.error?.(`clawgate: progress dispatch error: ${err}`),
        },
      });
    }
  } catch (err) {
    log?.error?.(`clawgate: [${accountId}] progress dispatch failed: ${err}`);
  }
}

/**
 * Handle a tmux completion event: Claude Code finished a task.
 * Dispatches the completion summary to AI, which then reports to LINE.
 * @param {object} params
 */
async function handleTmuxCompletion({ event, accountId, apiUrl, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const traceId = makeTraceId("tmux-completion", event);
  const payload = event.payload ?? {};
  payload.trace_id = traceId;
  const project = payload.project || payload.conversation || "unknown";
  const text = payload.text || "(no output captured)";
  const mode = payload.mode || sessionModes.get(project) || "observe"; // observe/auto/autonomous
  const tmuxTarget = payload.tmux_target || "";

  // Track session state for roster
  sessionModes.set(project, mode);
  sessionStatuses.set(project, "waiting_input");

  // Clear any pending question (completion means question was answered or session moved on)
  pendingQuestions.delete(project);

  // Keep last output in progress snapshot for roster visibility (waiting_input shows last output)
  setProgressSnapshot(project, text);

  // Resolve project path and register for roster
  if (tmuxTarget) {
    resolveProjectPath(project, tmuxTarget);
  }

  // Invalidate context cache (files may have changed during the task)
  invalidateProject(project);

  // Build two-layer context (stable + dynamic)
  const stable = getStableContext(project, tmuxTarget);
  const dynamic = getDynamicEnvelope(project, tmuxTarget);

  const contextParts = [];

  if (stable && stable.isNew && stable.context) {
    contextParts.push(`[Project Context (hash: ${stable.hash})]\n${stable.context}`);
    if (_ccKnowledge) {
      contextParts.push(_ccKnowledge);
    }
  } else if (stable && stable.hash) {
    contextParts.push(
      `[Project Context unchanged (hash: ${stable.hash}) - see earlier in conversation]`
    );
  }

  if (dynamic && dynamic.envelope) {
    contextParts.push(`[Current State]\n${dynamic.envelope}`);
  }

  let taskSummary;
  if (mode === "auto") {
    taskSummary = `[CC ${project}] [Auto]\n\nClaude Code output:\n\n${text}`;
  } else if (mode === "observe") {
    taskSummary = `[CC ${project}] [Observe]\n\nClaude Code completed a task:\n\n${text}`;
  } else if (mode === "autonomous") {
    taskSummary = `[CC ${project}] [Autonomous]\n\nClaude Code completed a task:\n\n${text}`;
  } else {
    taskSummary = `[CC ${project}]\n\nClaude Code completed a task:\n\n${text}`;
  }

  contextParts.push(buildPairingGuidance({ project, mode, eventKind: "completion" }));
  contextParts.push(taskSummary);
  const body = contextParts.join("\n\n---\n\n");

  const ctx = {
    Body: body,
    RawBody: body,
    CommandBody: body,
    From: `tmux:${project}`,
    To: `clawgate:${accountId}`,
    SessionKey: `clawgate:${accountId}:tmux:${project}`,
    AccountId: accountId,
    ChatType: "direct",
    Provider: "clawgate",
    Surface: "clawgate",
    ConversationLabel: defaultConversation || project,
    SenderName: `Claude Code (${project})`,
    SenderId: `tmux:${project}`,
    MessageSid: String(event.id ?? Date.now()),
    Timestamp: eventTimestamp(event),
    CommandAuthorized: true,
    OriginatingChannel: "clawgate",
    OriginatingTo: defaultConversation || project,
    _clawgateSource: "tmux_completion",
    _tmuxMode: mode,
  };

  log?.info?.(`clawgate: [${accountId}] tmux completion from "${project}" (mode=${mode}): "${text.slice(0, 80)}"`);

  // Dispatch to AI — the AI will summarize and reply via LINE
  // In autonomous mode, parse <cc_task> tags and route tasks to Claude Code
  const deliver = async (replyPayload) => {
    const replyText = extractReplyText(replyPayload, log, "tmux_completion");
    if (!replyText.trim()) return;

    // Autonomous/auto mode: try to extract and send <cc_task>
    if (mode === "autonomous") {
      const result = await tryExtractAndSendTask({
        replyText, project, apiUrl, traceId, log,
      });
      if (result) {
        if (result.error) {
          // Task send failed — forward everything to LINE with error notice
          const msg = `[Task send failed: ${result.error.message || result.error}]\n\n${result.lineText}`;
          try {
            await clawgateSend(apiUrl, defaultConversation || project, msg, traceId);
            recordPluginSend(msg);
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
          }
        } else {
          // Task sent successfully — send remaining text to LINE (if any)
          if (result.lineText) {
            try {
              await clawgateSend(apiUrl, defaultConversation || project, result.lineText, traceId);
              recordPluginSend(result.lineText);
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] send line text to LINE failed: ${err}`);
            }
          }
        }
        return;
      }
      // No <cc_task> found — fall through to normal delivery
    }

    // Default: forward all to LINE
    const lineText = normalizeLineReplyText(replyText, { project, eventKind: "completion" });
    log?.info?.(`clawgate: [${accountId}] sending tmux result to LINE "${defaultConversation}": "${lineText.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, defaultConversation || project, lineText, traceId);
      recordPluginSend(lineText);
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send tmux result to LINE failed: ${err}`);
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
          onError: (err) => log?.error?.(`clawgate: tmux dispatch error: ${err}`),
        },
      });
      // Mark stable context as sent after successful dispatch
      if (stable && stable.isNew && stable.hash) {
        markContextSent(project, stable.hash);
      }
    } else {
      log?.error?.("clawgate: dispatchReplyWithBufferedBlockDispatcher not found on runtime");
    }
  } catch (err) {
    log?.error?.(`clawgate: [${accountId}] tmux dispatch failed: ${err}`);
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
  setClawgateAuthToken(account.token || "");
  let pollIntervalMs = account.pollIntervalMs || 3000;
  let defaultConversation = account.defaultConversation || "";

  log?.info?.(`clawgate: [${accountId}] starting gateway (apiUrl=${apiUrl}, poll=${pollIntervalMs}ms, defaultConv="${defaultConversation}")`);

  // Wait for ClawGate to be reachable
  await waitForReady(apiUrl, abortSignal, log);
  if (abortSignal?.aborted) return;

  // Verify system health
  try {
    const doctor = await clawgateDoctor(apiUrl);
    if (doctor.ok) {
      log?.info?.(`clawgate: [${accountId}] doctor OK (${doctor.summary?.passed}/${doctor.summary?.total} checks passed)`);
    } else {
      log?.warn?.(`clawgate: [${accountId}] doctor reported issues: ${JSON.stringify(doctor.summary)}`);
    }
  } catch (err) {
    log?.warn?.(`clawgate: [${accountId}] doctor check failed: ${err}`);
  }

  // Fetch ClawGate config — fill in any values not set in openclaw.json
  try {
    const remoteConfig = await clawgateConfig(apiUrl);
    if (remoteConfig?.line) {
      if (!defaultConversation && remoteConfig.line.defaultConversation) {
        defaultConversation = remoteConfig.line.defaultConversation;
        log?.info?.(`clawgate: [${accountId}] defaultConversation from ClawGate config: "${defaultConversation}"`);
      }
      if (!account.pollIntervalMs && remoteConfig.line.pollIntervalSeconds) {
        pollIntervalMs = remoteConfig.line.pollIntervalSeconds * 1000;
        log?.info?.(`clawgate: [${accountId}] pollIntervalMs from ClawGate config: ${pollIntervalMs}`);
      }
    }
  } catch (err) {
    log?.debug?.(`clawgate: [${accountId}] config fetch failed (using defaults): ${err}`);
  }

  // Get initial cursor
  let cursor = 0;
  try {
    const initial = await clawgatePoll(apiUrl, 0);
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
      const poll = await clawgatePoll(apiUrl, cursor);

      if (poll.ok && poll.events?.length > 0) {
        for (const event of poll.events) {
          if (abortSignal?.aborted) break;

          // Only process inbound_message events (skip echo_message, heartbeat, etc.)
          if (event.type !== "inbound_message") continue;
          const traceId = makeTraceId("event", event);
          if (!event.payload) event.payload = {};
          event.payload.trace_id = traceId;
          traceLog(log, "info", {
            trace_id: traceId,
            stage: "ingress_received",
            action: "poll_event",
            status: "ok",
            adapter: event.adapter || "unknown",
            source: event.payload?.source || "poll",
          });

          // Track tmux session state for roster
          if (event.adapter === "tmux" && event.payload?.project) {
            const proj = event.payload.project;
            const tmuxTgt = event.payload.tmux_target || "";
            if (event.payload.mode) sessionModes.set(proj, event.payload.mode);
            if (event.payload.status) sessionStatuses.set(proj, event.payload.status);
            if (tmuxTgt) resolveProjectPath(proj, tmuxTgt);
          }

          // Mode gate: ignore sessions must not be processed even if stale events arrive.
          if (event.adapter === "tmux") {
            const proj = event.payload?.project || "";
            const effectiveMode = event.payload?.mode || sessionModes.get(proj) || "ignore";
            if (effectiveMode === "ignore") {
              continue;
            }
          }

          // Handle tmux progress events (output during running)
          if (event.adapter === "tmux" && event.payload?.source === "progress") {
            const proj = event.payload.project;
            setProgressSnapshot(proj, event.payload.text || "");
            sessionStatuses.set(proj, "running");

            // Dispatch progress to AI for non-ignore modes (throttled)
            const progressMode = event.payload.mode || sessionModes.get(proj) || "ignore";
            if (progressMode !== "ignore" && shouldDispatchProgress(proj)) {
              try {
                await handleTmuxProgress({ event, accountId, apiUrl, cfg, defaultConversation, log });
              } catch (err) {
                log?.error?.(`clawgate: [${accountId}] handleTmuxProgress failed: ${err}`);
              }
            }
            continue;
          }

          // Handle tmux question events (AskUserQuestion)
          if (event.adapter === "tmux" && event.payload?.source === "question") {
            try {
              await handleTmuxQuestion({ event, accountId, apiUrl, cfg, defaultConversation, log });
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] handleTmuxQuestion failed: ${err}`);
              traceLog(log, "error", {
                trace_id: traceId,
                stage: "gateway_forward_failed",
                action: "handle_tmux_question",
                status: "failed",
                error: String(err),
              });
            }
            continue;
          }

          // Handle tmux completion events separately
          if (event.adapter === "tmux" && event.payload?.source === "completion") {
            try {
              await handleTmuxCompletion({ event, accountId, apiUrl, cfg, defaultConversation, log });
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] handleTmuxCompletion failed: ${err}`);
              traceLog(log, "error", {
                trace_id: traceId,
                stage: "gateway_forward_failed",
                action: "handle_tmux_completion",
                status: "failed",
                error: String(err),
              });
            }
            continue;
          }

          const source = event.payload?.source || "poll";
          const conversation = event.payload?.conversation || "";
          const rawEventText = event.payload?.text || "";
          const eventText = normalizeInboundText(rawEventText, source);

          // Skip only near-empty texts; keep short Japanese lines for recall.
          if (eventText.trim().length < MIN_TEXT_LENGTH) {
            log?.debug?.(`clawgate: [${accountId}] skipped short/noisy text (raw=${rawEventText.length}, clean=${eventText.length})`);
            continue;
          }

          // Plugin-level echo suppression (ClawGate's 8s window is too short for AI replies)
          if (isPluginEcho(eventText)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed echo: "${eventText.slice(0, 60)}"`);
            continue;
          }

          // Cross-source deduplication (AXRow / PixelDiff / NotificationBanner)
          if (isDuplicateInbound(eventText)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed duplicate: "${eventText.slice(0, 60)}"`);
            continue;
          }
          if (isStaleRepeatInbound(eventText, conversation, source)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed stale repeat: "${eventText.slice(0, 60)}"`);
            continue;
          }

          // Record before dispatch so subsequent duplicates are caught
          recordInbound(eventText);
          recordStableInbound(eventText, conversation);
          if (event.payload) {
            event.payload.text = eventText;
          }

          try {
            await handleInboundMessage({
              event,
              accountId,
              apiUrl,
              cfg,
              defaultConversation,
              log,
            });
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] handleInboundMessage failed: ${err}`);
            traceLog(log, "error", {
              trace_id: traceId,
              stage: "gateway_forward_failed",
              action: "handle_inbound_message",
              status: "failed",
              error: String(err),
            });
          }
        }
        cursor = poll.next_cursor ?? cursor;
      }
    } catch (err) {
      if (abortSignal?.aborted) break;
      log?.error?.(`clawgate: [${accountId}] poll error: ${err}`);
    }

    await sleep(pollIntervalMs, abortSignal);
  }

  log?.info?.(`clawgate: [${accountId}] gateway stopped`);
}

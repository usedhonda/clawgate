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

// ── Pending questions tracking ────────────────────────────────
// Tracks AskUserQuestion menus displayed in Claude Code sessions.
// Used by roster and answer routing.

/** @type {Map<string, { questionText: string, questionId: string, options: string[], selectedIndex: number }>} */
const pendingQuestions = new Map();

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
async function tryExtractAndSendTask({ replyText, project, apiUrl, log }) {
  const taskMatch = replyText.match(/<cc_task>([\s\S]*?)<\/cc_task>/);
  if (!taskMatch) return null;

  const taskText = taskMatch[1].trim();
  if (!taskText) return null;

  const lineText = replyText.replace(/<cc_task>[\s\S]*?<\/cc_task>/, "").trim();

  // Prefix task with [OpenClaw Agent] so CC knows the origin
  const prefixedTask = `[OpenClaw Agent] ${taskText}`;

  try {
    const result = await clawgateTmuxSend(apiUrl, project, prefixedTask);
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
async function tryExtractAndSendAnswer({ replyText, apiUrl, log }) {
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
    const result = await clawgateTmuxSend(apiUrl, project, selectCmd);
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
  const hasTaskCapable = [...sessionModes.values()].some((m) => m === "autonomous" || m === "auto");
  const taskHint = hasTaskCapable
    ? `\nYou can send tasks to autonomous projects by including <cc_task>your task</cc_task> in your reply. Text outside the tags goes to LINE.`
    : "";

  // Check for pending questions
  const hasQuestions = pendingQuestions.size > 0;
  const answerHint = hasQuestions
    ? `\nTo answer a pending question, include <cc_answer project="name">{option number}</cc_answer> in your reply.`
    : "";

  return `[Active Claude Code Projects]\n${roster}${taskHint}${answerHint}`;
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

  // Find task-capable projects (autonomous or auto) for potential task routing from LINE replies
  const taskCapableProjects = [...sessionModes.entries()]
    .filter(([, m]) => m === "autonomous" || m === "auto")
    .map(([p]) => p);

  // Dispatch to AI using runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher
  const deliver = async (payload) => {
    const text = payload.text || payload.body || "";
    if (!text.trim()) return;

    // Try to extract <cc_answer> first (from AI reply to question)
    const answerResult = await tryExtractAndSendAnswer({ replyText: text, apiUrl, log });
    if (answerResult) {
      if (answerResult.error) {
        const msg = `[Answer send failed: ${answerResult.error.message || answerResult.error}]\n\n${answerResult.lineText}`;
        try { await clawgateSend(apiUrl, conversation, msg); recordPluginSend(msg); } catch {}
      } else if (answerResult.lineText) {
        try { await clawgateSend(apiUrl, conversation, answerResult.lineText); recordPluginSend(answerResult.lineText); } catch {}
      }
      return;
    }

    // If there are task-capable projects, try to extract <cc_task> from AI reply
    if (taskCapableProjects.length > 0) {
      const result = await tryExtractAndSendTask({
        replyText: text, project: taskCapableProjects[0], apiUrl, log,
      });
      if (result) {
        if (result.error) {
          const msg = `[Task send failed: ${result.error.message || result.error}]\n\n${result.lineText}`;
          try {
            await clawgateSend(apiUrl, conversation, msg);
            recordPluginSend(msg);
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
          }
        } else if (result.lineText) {
          try {
            await clawgateSend(apiUrl, conversation, result.lineText);
            recordPluginSend(result.lineText);
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send line reply failed: ${err}`);
          }
        }
        return;
      }
    }

    log?.info?.(`clawgate: [${accountId}] sending reply to "${conversation}": "${text.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, conversation, text);
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
 * Handle a tmux question event: Claude Code is displaying an AskUserQuestion menu.
 * Dispatches the question + options to AI, which can answer via <cc_answer>.
 * @param {object} params
 */
async function handleTmuxQuestion({ event, accountId, apiUrl, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const payload = event.payload ?? {};
  const project = payload.project || payload.conversation || "unknown";
  const questionText = payload.question_text || payload.text || "(no question)";
  const optionsRaw = payload.question_options || "";
  const selectedIndex = parseInt(payload.question_selected || "0", 10);
  const questionId = payload.question_id || String(Date.now());
  const mode = payload.mode || "autonomous";
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

  const body = `[Claude Code (${project}) is asking a question]\n\n${questionText}\n\nOptions:\n${numberedOptions}\n\n[To answer, include <cc_answer project="${project}">{option number}</cc_answer> in your reply. Use 1-based numbering (1 = first option). Text outside the tag goes to LINE.]`;

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
    Timestamp: event.observed_at ? Date.parse(event.observed_at) : Date.now(),
    CommandAuthorized: true,
    OriginatingChannel: "clawgate",
    OriginatingTo: defaultConversation || project,
    _clawgateSource: "tmux_question",
    _tmuxMode: mode,
  };

  log?.info?.(`clawgate: [${accountId}] tmux question from "${project}": "${questionText.slice(0, 80)}" (${options.length} options)`);

  // Deliver reply — parse <cc_answer> and route answer, or forward to LINE
  const deliver = async (replyPayload) => {
    const replyText = replyPayload.text || replyPayload.body || "";
    if (!replyText.trim()) return;

    // Try to extract <cc_answer> first
    const answerResult = await tryExtractAndSendAnswer({ replyText, apiUrl, log });
    if (answerResult) {
      if (answerResult.error) {
        const msg = `[Answer send failed: ${answerResult.error.message || answerResult.error}]\n\n${answerResult.lineText}`;
        try {
          await clawgateSend(apiUrl, defaultConversation || project, msg);
          recordPluginSend(msg);
        } catch (err) {
          log?.error?.(`clawgate: [${accountId}] send answer error notice to LINE failed: ${err}`);
        }
      } else if (answerResult.lineText) {
        try {
          await clawgateSend(apiUrl, defaultConversation || project, answerResult.lineText);
          recordPluginSend(answerResult.lineText);
        } catch (err) {
          log?.error?.(`clawgate: [${accountId}] send answer line text to LINE failed: ${err}`);
        }
      }
      return;
    }

    // No <cc_answer> — try <cc_task> fallback (autonomous mode)
    if (mode === "autonomous" || mode === "auto") {
      const taskResult = await tryExtractAndSendTask({ replyText, project, apiUrl, log });
      if (taskResult) {
        if (taskResult.error) {
          const msg = `[Task send failed: ${taskResult.error.message || taskResult.error}]\n\n${taskResult.lineText}`;
          try { await clawgateSend(apiUrl, defaultConversation || project, msg); recordPluginSend(msg); } catch {}
        } else if (taskResult.lineText) {
          try { await clawgateSend(apiUrl, defaultConversation || project, taskResult.lineText); recordPluginSend(taskResult.lineText); } catch {}
        }
        return;
      }
    }

    // Default: forward to LINE
    log?.info?.(`clawgate: [${accountId}] sending question reply to LINE: "${replyText.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, defaultConversation || project, replyText);
      recordPluginSend(replyText);
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
 * Handle a tmux completion event: Claude Code finished a task.
 * Dispatches the completion summary to AI, which then reports to LINE.
 * @param {object} params
 */
async function handleTmuxCompletion({ event, accountId, apiUrl, cfg, defaultConversation, log }) {
  const runtime = getRuntime();
  const payload = event.payload ?? {};
  const project = payload.project || payload.conversation || "unknown";
  const text = payload.text || "(no output captured)";
  const mode = payload.mode || "autonomous"; // "observe" or "autonomous"
  const tmuxTarget = payload.tmux_target || "";

  // Track session state for roster
  sessionModes.set(project, mode);
  sessionStatuses.set(project, "waiting_input");

  // Clear any pending question (completion means question was answered or session moved on)
  pendingQuestions.delete(project);

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
  if (mode === "observe") {
    taskSummary = `[OBSERVE MODE - You can comment, suggest, and give opinions, but do NOT send tasks to Claude Code]\n\nClaude Code (${project}) completed a task:\n\n${text}`;
  } else if (mode === "auto") {
    taskSummary = `[AUTO MODE - You are a task driver. Your ONLY job is to keep Claude Code working until everything is done.\n- If there are ANY remaining or pending tasks in the output, immediately send: <cc_task>There are still pending tasks. Continue working — do not stop until all tasks are complete.</cc_task>\n- ONLY when ALL tasks are genuinely complete, report the final result to the user on LINE.\n- Do NOT design new tasks. Do NOT add your own ideas. Just crack the whip and keep Claude Code moving.]\n\nClaude Code (${project}) output:\n\n${text}`;
  } else if (mode === "autonomous") {
    taskSummary = `[AUTONOMOUS MODE - You may send a follow-up task to Claude Code by wrapping it in <cc_task>your task here</cc_task> tags. Only send a task when you have a clear, actionable follow-up. Do not send tasks just because you can. Your message outside the tags goes to the user on LINE.]\n\nClaude Code (${project}) completed a task:\n\n${text}`;
  } else {
    taskSummary = `Claude Code (${project}) completed a task:\n\n${text}`;
  }

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
    Timestamp: event.observed_at ? Date.parse(event.observed_at) : Date.now(),
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
    const replyText = replyPayload.text || replyPayload.body || "";
    if (!replyText.trim()) return;

    // Autonomous/auto mode: try to extract and send <cc_task>
    if (mode === "autonomous" || mode === "auto") {
      const result = await tryExtractAndSendTask({
        replyText, project, apiUrl, log,
      });
      if (result) {
        if (result.error) {
          // Task send failed — forward everything to LINE with error notice
          const msg = `[Task send failed: ${result.error.message || result.error}]\n\n${result.lineText}`;
          try {
            await clawgateSend(apiUrl, defaultConversation || project, msg);
            recordPluginSend(msg);
          } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
          }
        } else {
          // Task sent successfully — send remaining text to LINE (if any)
          if (result.lineText) {
            try {
              await clawgateSend(apiUrl, defaultConversation || project, result.lineText);
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
    log?.info?.(`clawgate: [${accountId}] sending tmux result to LINE "${defaultConversation}": "${replyText.slice(0, 80)}"`);
    try {
      await clawgateSend(apiUrl, defaultConversation || project, replyText);
      recordPluginSend(replyText);
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

          // Track tmux session state for roster
          if (event.adapter === "tmux" && event.payload?.project) {
            const proj = event.payload.project;
            const tmuxTgt = event.payload.tmux_target || "";
            if (event.payload.mode) sessionModes.set(proj, event.payload.mode);
            if (event.payload.status) sessionStatuses.set(proj, event.payload.status);
            if (tmuxTgt) resolveProjectPath(proj, tmuxTgt);
          }

          // Handle tmux question events (AskUserQuestion)
          if (event.adapter === "tmux" && event.payload?.source === "question") {
            try {
              await handleTmuxQuestion({ event, accountId, apiUrl, cfg, defaultConversation, log });
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] handleTmuxQuestion failed: ${err}`);
            }
            continue;
          }

          // Handle tmux completion events separately
          if (event.adapter === "tmux" && event.payload?.source === "completion") {
            try {
              await handleTmuxCompletion({ event, accountId, apiUrl, cfg, defaultConversation, log });
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] handleTmuxCompletion failed: ${err}`);
            }
            continue;
          }

          const eventText = event.payload?.text || "";

          // Skip empty/short texts (OCR noise, read-receipts, scroll artifacts)
          if (eventText.trim().length < MIN_TEXT_LENGTH) {
            log?.debug?.(`clawgate: [${accountId}] skipped short text (${eventText.length} chars)`);
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

          // Record before dispatch so subsequent duplicates are caught
          recordInbound(eventText);

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

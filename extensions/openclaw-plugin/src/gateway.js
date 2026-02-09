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

// ── Autonomous task chaining ──────────────────────────────────
const MAX_CONSECUTIVE_TASKS = 5;
/** @type {Map<string, number>} project -> consecutive task count */
const consecutiveTaskCount = new Map();

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

  // Check consecutive task limit
  const count = (consecutiveTaskCount.get(project) || 0) + 1;
  if (count > MAX_CONSECUTIVE_TASKS) {
    log?.warn?.(`clawgate: consecutive task limit reached (${MAX_CONSECUTIVE_TASKS}) for ${project}, skipping task`);
    const limitMsg = `[Task chain limit reached (${MAX_CONSECUTIVE_TASKS}). Sending full reply to LINE instead.]\n\n${replyText}`;
    consecutiveTaskCount.set(project, 0);
    return { error: new Error("consecutive task limit reached"), lineText: limitMsg };
  }

  try {
    const result = await clawgateTmuxSend(apiUrl, project, taskText);
    if (result?.ok) {
      consecutiveTaskCount.set(project, count);
      log?.info?.(`clawgate: task ${count}/${MAX_CONSECUTIVE_TASKS} sent to CC (${project}): "${taskText.slice(0, 80)}"`);
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
 * Reset consecutive task counter for a project (called on human input or completion without task).
 */
function resetTaskChain(project) {
  consecutiveTaskCount.set(project, 0);
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
  const roster = getProjectRoster(sessionModes, sessionStatuses);
  if (!roster) return "";

  // Check if any project is in autonomous mode
  const hasAutonomous = [...sessionModes.values()].some((m) => m === "autonomous");
  const taskHint = hasAutonomous
    ? `\nYou can send tasks to autonomous projects by including <cc_task>your task</cc_task> in your reply. Text outside the tags goes to LINE.`
    : "";

  return `[Active Claude Code Projects]\n${roster}${taskHint}`;
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

  // Human input resets all task chain counters (user is back in the loop)
  for (const project of consecutiveTaskCount.keys()) {
    resetTaskChain(project);
  }

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

  // Find autonomous projects for potential task routing from LINE replies
  const autonomousProjects = [...sessionModes.entries()]
    .filter(([, m]) => m === "autonomous")
    .map(([p]) => p);

  // Dispatch to AI using runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher
  const deliver = async (payload) => {
    const text = payload.text || payload.body || "";
    if (!text.trim()) return;

    // If there are autonomous projects, try to extract <cc_task> from AI reply
    if (autonomousProjects.length > 0) {
      const result = await tryExtractAndSendTask({
        replyText: text, project: autonomousProjects[0], apiUrl, log,
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
  } else if (mode === "autonomous") {
    const chainCount = consecutiveTaskCount.get(project) || 0;
    const remaining = MAX_CONSECUTIVE_TASKS - chainCount;
    taskSummary = `[AUTONOMOUS MODE - You may send a follow-up task to Claude Code by wrapping it in <cc_task>your task here</cc_task> tags. Only send a task when you have a clear, actionable follow-up. Do not send tasks just because you can. Your message outside the tags goes to the user on LINE. Chain: ${chainCount}/${MAX_CONSECUTIVE_TASKS} (${remaining} remaining)]\n\nClaude Code (${project}) completed a task:\n\n${text}`;
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

    // Autonomous mode: try to extract and send <cc_task>
    if (mode === "autonomous") {
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
      // No <cc_task> found — reset chain counter and fall through to normal delivery
      resetTaskChain(project);
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

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
import { setActiveProject, clearActiveProject } from "./shared-state.js";
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
  appendProgressTrail,
  getProgressTrail,
  clearProgressTrail,
  setTaskGoal,
  getTaskGoal,
  clearTaskGoal,
  filterPaneNoise,
  deduplicateTrailAgainst,
  capText,
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

// ── Pairing guidance dedup (full guidance sent once per project) ──
/** @type {Set<string>} */
const guidanceSentProjects = new Set();

// ── Autonomous conversation round tracking ──────────────────────
// Tracks how many completion->question rounds Chi has had with CC per project.
// Reset on question events, incremented on completion when Chi sends <cc_task>.
/** @type {Map<string, number>} project -> round count */
const questionRoundMap = new Map();

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
  // Owner's LINE display name — treated as noise in AX tree parsing
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

function sessionLabel(sessionType) {
  return sessionType === "codex" ? "Codex" : "CC";
}

function normalizeLineReplyText(text, { project = "", sessionType = "claude_code", eventKind = "reply" } = {}) {
  const trimmed = `${text || ""}`.replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  if (!trimmed) return "";

  let result = trimmed
    .replace(/\n{3,}/g, "\n\n")
    .replace(/\s+\n/g, "\n")
    .trim();

  // Add blank line before bold section headers, then strip the bold markers.
  // (Fallback: AI may still use bold even when told not to.)
  result = result.replace(/(?<=\S)\n(\*\*.+?\*\*)/g, "\n\n$1");
  result = result.replace(/\*\*(.+?)\*\*/g, "$1");
  // Strip Markdown heading markers.
  result = result.replace(/^#{1,6}\s+/gm, "");
  // Ensure blank line before known review section labels (SCOPE:, RISK:, etc.)
  // so the output is readable even when AI forgets to add spacing.
  result = result.replace(/(?<=\S)\n((?:GOAL|SCOPE|RISK|ARCHITECTURE|MISSING|SUMMARY|VERDICT):)/g, "\n\n$1");

  // Keep a compact prefix for tmux-origin messages so users can distinguish
  // CC updates from normal LINE conversations at a glance.
  // Strip any existing [CC/Codex ...] prefix (Chi may have added one) before re-adding
  // to ensure consistent formatting.
  if (project) {
    result = result.replace(/^\[(CC|Codex) [^\]]*\]\n?/, "").trim();
    result = `[${sessionLabel(sessionType)} ${project}]\n${result}`;
  }

  return result;
}

function buildPairingGuidance({ project = "", mode = "", eventKind = "", sessionType = "claude_code", firstTime = false } = {}) {
  const proj = project || "current";
  const m = mode || "observe";
  const k = eventKind || "update";
  const label = sessionLabel(sessionType);
  const parts = [];

  if (firstTime) {
    parts.push(
      `[Pair Review] [${label} ${proj}] Mode: ${m}`,
      "",
      `${label}（${sessionType === "codex" ? "Codex" : "Claude Code"}）が ${proj} で作業した内容をレビューする役割。`,
      "SOUL.md のキャラ・話し方・書式ルールをそのまま守って。レビューだからって崩さない。",
      "LINE は Markdown 非対応（太字・見出し・コードブロック全部ダメ）。",
      "",
      "書式: 英語ラベル + 空行区切り（各ラベルの前に必ず空行を入れる）。例:",
      "",
      "SCOPE: gateway.js のみ。問題なし。",
      "",
      "RISK: API の破壊的変更あり。エラー処理も漏れてる。",
      "",
      "↑このように SCOPE: と RISK: の間に空行。詰めて書かない。",
      "",
      "観点（気になったものだけ）:",
      "- GOAL: 目的と結果が合ってるか",
      "- SCOPE: 余計なファイルまで触ってないか",
      "- RISK: 削除、API変更、エラー処理漏れ、未テスト",
      "- ARCHITECTURE: プロジェクトのパターンに合ってるか",
      "- MISSING: テスト、ドキュメント、エッジケース",
      "",
      "気になった点は掘り下げてOK。全体で5〜15行くらい。問題なければ短くOKでも。",
      "コミットメッセージの復唱、「CCが〜しました」的な要約、とりあえず褒める、は不要。",
      "必ず返信すること（NO_REPLY 禁止）。",
      "",
      "モード別:",
      "- AUTO: 品質ゲート。問題なければ <cc_task>continue</cc_task> で続行。ブロッキング問題があればタスクを送らずユーザーに報告。",
      "- AUTONOMOUS: 完了時はレビュー後、気になった点や疑問を <cc_task> で CC に質問（意思決定ではなく質問・深掘りのキャラ）。選択肢の質問はユーザーに LINE でアドバイス。",
      "- OBSERVE: レビューしてユーザーに報告。選択肢の質問もLINEで推奨を伝える。CC には直接介入しない。",
    );
  }

  // Per-event guidance
  if (k === "completion") {
    parts.push(`[完了イベント] タスクのゴールと結果を比較してレビュー。`);
    if (m === "autonomous") {
      parts.push("レビュー後、気になった点・疑問・確認事項があれば <cc_task> で CC に質問。");
      parts.push("意思決定するのではなく、質問・深掘り・確認をするキャラ。");
      parts.push("CC と数往復会話して納得したら、<cc_task> を含めずにユーザー向けの所感を LINE に送る（任意）。");
    } else if (m === "observe") {
      parts.push("レビューしてユーザーに報告。タスクは送らない。");
    } else if (m === "auto") {
      parts.push("品質ゲート。レビュー後:");
      parts.push("- 問題なし/軽微: <cc_task>continue</cc_task> で続行。");
      parts.push("- ブロッキング問題あり: <cc_task> は送らない。ユーザーに LINE で報告。");
    }
    parts.push("必ず返信（NO_REPLY 禁止）。");
  } else if (k === "question") {
    if (m === "auto") {
      parts.push(
        "[質問イベント] 選択肢を評価。",
        "正解がわかるなら <cc_answer> で回答。",
        "判断に迷うならユーザーに転送（自分の推奨も添えて）。",
      );
    } else if (m === "autonomous") {
      parts.push(
        "[質問イベント] 選択肢を分析してユーザーに LINE でアドバイス。",
        "<cc_answer> は使わない。ユーザーが判断する。",
        "自分の推奨理由を添えること。",
      );
    } else if (m === "observe") {
      parts.push(
        "[質問イベント] 選択肢を分析してユーザーに LINE で推奨を伝える。",
        "<cc_answer> は使わない。ユーザーが判断する。",
      );
    }
    parts.push("必ず返信（NO_REPLY 禁止）。");
  }

  return parts.join("\n");
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
async function tryExtractAndSendTask({ replyText, project, apiUrl, traceId, log, mode }) {
  const taskMatch = replyText.match(/<cc_task>([\s\S]*?)<\/cc_task>/);
  if (!taskMatch) return null;

  const taskText = taskMatch[1].trim();
  if (!taskText) return null;

  const lineText = replyText.replace(/<cc_task>[\s\S]*?<\/cc_task>/, "").trim();

  // Prefix task with [OpenClaw Agent - {Mode}] so CC knows the origin and mode
  const modeLabel = mode ? mode.charAt(0).toUpperCase() + mode.slice(1) : "Unknown";
  const prefixedTask = `[OpenClaw Agent - ${modeLabel}] ${taskText}`;

  try {
    const result = await clawgateTmuxSend(apiUrl, project, prefixedTask, traceId);
    if (result?.ok) {
      log?.info?.(`clawgate: task sent to CC (${project}): "${taskText.slice(0, 80)}"`);
      setTaskGoal(project, taskText);
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
  const hasTaskCapable = [...sessionModes.values()].some((m) => m === "autonomous" || m === "auto");
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

  // Clear active project so outbound.sendText doesn't leak tmux prefixes into LINE replies
  clearActiveProject(defaultConversation || conversation);

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
      const taskProject = taskCapableProjects[0];
      const taskMode = sessionModes.get(taskProject) || "autonomous";
      const result = await tryExtractAndSendTask({
        replyText: text, project: taskProject, apiUrl, traceId, log, mode: taskMode,
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

    const lineText = normalizeLineReplyText(text, { project: event.payload?.project || "" });
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
async function handleTmuxQuestion({ event, accountId, apiUrl, cfg, defaultConversation, log, lineAvailable = true }) {
  const runtime = getRuntime();
  const traceId = makeTraceId("tmux-question", event);
  const payload = event.payload ?? {};
  payload.trace_id = traceId;
  const project = payload.project || payload.conversation || "unknown";
  const questionText = payload.question_text || payload.text || "(no question)";
  const optionsRaw = payload.question_options || "";
  const selectedIndex = parseInt(payload.question_selected || "0", 10);
  const questionId = payload.question_id || String(Date.now());
  const mode = payload.mode || sessionModes.get(project) || "ignore";
  const sessionType = payload.session_type || "claude_code";
  const tmuxTarget = payload.tmux_target || "";
  const label = sessionLabel(sessionType);

  // Guard: ignore-mode sessions must not be dispatched (defense against federation leaks)
  if (mode === "ignore") {
    log?.debug?.(`clawgate: [${accountId}] skipping question for "${project}" — mode=ignore`);
    return;
  }

  // Track session state
  sessionModes.set(project, mode);
  sessionStatuses.set(project, "waiting_input");

  // Reset autonomous conversation round counter (question = CC responded, not Chi's turn)
  questionRoundMap.delete(project);

  // Track pending question
  const options = optionsRaw.split("\n").filter(Boolean);
  pendingQuestions.set(project, { questionText, questionId, options, selectedIndex });

  if (tmuxTarget) resolveProjectPath(project, tmuxTarget);

  // Invalidate context cache (files may have changed while CC was working)
  invalidateProject(project);

  // --- Context layers (parallel to handleTmuxCompletion) ---
  const stable = getStableContext(project, tmuxTarget);
  const dynamic = getDynamicEnvelope(project, tmuxTarget);

  const contextParts = [];

  // Stable project context
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

  // Task goal (what Chi asked CC to do — helps Chi understand what the question is about)
  // Note: DON'T clearTaskGoal here — question doesn't end the task
  const taskGoal = getTaskGoal(project);
  if (taskGoal) {
    contextParts.push(`[Task Goal]\n${taskGoal}`);
  }

  // Dynamic envelope (git state)
  if (dynamic && dynamic.envelope) {
    contextParts.push(`[Current State]\n${dynamic.envelope}`);
  }

  // Pane context (output above the question — may contain plan content)
  // Filter noise and cap before trail so we can dedup trail against it
  const MAX_QUESTION_CONTEXT_CHARS = 3000;
  let questionContext = filterPaneNoise(payload.question_context || "");
  if (questionContext) {
    questionContext = capText(questionContext, MAX_QUESTION_CONTEXT_CHARS, "tail");
    contextParts.push(`[Screen Context (above question)]\n${questionContext}`);
  }

  // Progress trail (what CC did so far — helps Chi understand the question in context)
  // Note: DON'T clearProgressTrail — question doesn't end the task
  // Deduplicate against questionContext to avoid repeating the same content
  const trail = getProgressTrail(project);
  if (trail && questionContext) {
    const deduped = deduplicateTrailAgainst(trail, questionContext);
    if (deduped) contextParts.push(`[Execution Progress Trail]\n${deduped}`);
  } else if (trail) {
    contextParts.push(`[Execution Progress Trail]\n${trail}`);
  }

  // Pairing guidance
  const isFirstGuidance = !guidanceSentProjects.has(project);
  contextParts.push(buildPairingGuidance({ project, mode, eventKind: "question", sessionType, firstTime: isFirstGuidance }));
  if (isFirstGuidance) guidanceSentProjects.add(project);

  // Format numbered options for Chi
  const numberedOptions = options.map((opt, i) => {
    const marker = i === selectedIndex ? ">>>" : "   ";
    return `${marker} ${i + 1}. ${opt}`;
  }).join("\n");

  // Question body
  let questionBody;
  if (mode === "auto") {
    questionBody = `[${label} ${project}] Claude Code is asking a question:\n\n${questionText}\n\nOptions:\n${numberedOptions}\n\n[To answer, include <cc_answer project="${project}">{option number}</cc_answer> in your reply. Use 1-based numbering (1 = first option). Text outside the tag goes to LINE.]`;
  } else {
    questionBody = `[${label} ${project}] Claude Code is asking a question:\n\n${questionText}\n\nOptions:\n${numberedOptions}\n\n[Analyze the options and send your recommendation to the user via LINE. Do NOT use <cc_answer>.]`;
  }
  contextParts.push(questionBody);

  // Apply total message cap (tail-priority: question body at the end is most important)
  const MAX_TOTAL_BODY_CHARS = 16000;
  let body = contextParts.join("\n\n---\n\n");
  if (body.length > MAX_TOTAL_BODY_CHARS) {
    body = capText(body, MAX_TOTAL_BODY_CHARS, "tail");
  }

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
    _clawgateSource: "tmux_question",
    _tmuxMode: mode,
  };

  log?.info?.(`clawgate: [${accountId}] tmux question from "${project}": "${questionText.slice(0, 80)}" (${options.length} options)`);

  // Helper: send to LINE only when LINE is available
  const sendLine = async (conv, text) => {
    if (!lineAvailable) { log?.debug?.(`clawgate: [${accountId}] LINE skip (lineAvailable=false)`); return; }
    const result = await clawgateSend(apiUrl, conv, text, traceId);
    if (!result?.ok) {
      log?.warn?.(`clawgate: sendLine failed (question): ${JSON.stringify(result?.error || result)}`);
    }
    recordPluginSend(text);
  };

  // Deliver reply — parse <cc_answer> (auto mode only) and route answer, or forward to LINE
  const deliver = async (replyPayload) => {
    const replyText = extractReplyText(replyPayload, log, "tmux_question");
    if (!replyText.trim()) return;

    // Auto mode only: try <cc_answer> to auto-select
    if (mode === "auto") {
      const answerResult = await tryExtractAndSendAnswer({ replyText, apiUrl, traceId, log });
      if (answerResult) {
        if (answerResult.error) {
          const msg = `[Answer send failed: ${answerResult.error.message || answerResult.error}]\n\n${answerResult.lineText}`;
          try { await sendLine(defaultConversation || project, msg); } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send answer error notice to LINE failed: ${err}`);
          }
        } else if (answerResult.lineText) {
          const normalized = normalizeLineReplyText(answerResult.lineText, { project, sessionType, eventKind: "question" });
          try { await sendLine(defaultConversation || project, normalized); } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send answer line text to LINE failed: ${err}`);
          }
        }
        return;
      }
    }

    // Default: forward to LINE (observe, autonomous, auto fallback)
    const lineText = normalizeLineReplyText(replyText, { project, sessionType, eventKind: "question" });
    log?.info?.(`clawgate: [${accountId}] sending question reply to LINE: "${lineText.slice(0, 80)}"`);
    try {
      await sendLine(defaultConversation || project, lineText);
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send question reply to LINE failed: ${err}`);
    }
  };

  // Register project context for outbound.sendText prefix fallback
  setActiveProject(defaultConversation || project, project, sessionType);

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
      // Mark stable context as sent after successful dispatch
      if (stable && stable.isNew && stable.hash) {
        markContextSent(project, stable.hash);
      }
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
async function handleTmuxCompletion({ event, accountId, apiUrl, cfg, defaultConversation, log, lineAvailable = true }) {
  const runtime = getRuntime();
  const traceId = makeTraceId("tmux-completion", event);
  const payload = event.payload ?? {};
  payload.trace_id = traceId;
  const project = payload.project || payload.conversation || "unknown";
  const text = payload.text || "(no output captured)";
  const mode = payload.mode || sessionModes.get(project) || "ignore";
  const sessionType = payload.session_type || "claude_code";
  const tmuxTarget = payload.tmux_target || "";

  // Guard: ignore-mode sessions must not be dispatched (defense against federation leaks)
  if (mode === "ignore") {
    log?.debug?.(`clawgate: [${accountId}] skipping completion for "${project}" — mode=ignore`);
    return;
  }

  // Guard: skip useless capture-failed completions — no point dispatching to AI
  if (text === "(capture failed)" || text === "(no output captured)") {
    log?.warn?.(`clawgate: [${accountId}] skipping completion dispatch for "${project}" — ${text}`);
    return;
  }

  // Guard: bootstrap completions are session-discovery snapshots (e.g. Codex welcome screen)
  // — not actual task completions. Update state but don't dispatch to AI.
  const capture = payload.capture || "";
  if (capture === "idle_bootstrap") {
    log?.info?.(`clawgate: [${accountId}] skipping bootstrap completion for "${project}" (capture=idle_bootstrap)`);
    sessionModes.set(project, mode);
    sessionStatuses.set(project, "waiting_input");
    return;
  }

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

  // Task goal (what Chi asked CC to do — enables goal vs result comparison)
  const taskGoal = getTaskGoal(project);
  if (taskGoal) {
    contextParts.push(`[Task Goal]\n${taskGoal}`);
  }
  clearTaskGoal(project);

  if (dynamic && dynamic.envelope) {
    contextParts.push(`[Current State]\n${dynamic.envelope}`);
  }

  // Filter noise from completion text (CC UI chrome: bars, spinners, etc.)
  const cleanedText = filterPaneNoise(text);
  const displayText = cleanedText || text; // fallback if everything was noise

  // Include accumulated progress trail (what CC did between progress events)
  // Deduplicate against completion text to avoid repeating the same content
  const trail = getProgressTrail(project);
  if (trail) {
    const deduped = deduplicateTrailAgainst(trail, displayText);
    if (deduped) contextParts.push(`[Execution Progress Trail]\n${deduped}`);
  }
  clearProgressTrail(project);

  const isFirstGuidance = !guidanceSentProjects.has(project);
  contextParts.push(buildPairingGuidance({ project, mode, eventKind: "completion", sessionType, firstTime: isFirstGuidance }));
  if (isFirstGuidance) guidanceSentProjects.add(project);

  // Append metadata notes so Chi understands information gaps
  const hasGoal = !!taskGoal;
  const hasUncommitted = dynamic?.envelope?.includes("Uncommitted changes:");
  const hasTrail = !!trail;
  const metaNotes = [
    !hasGoal ? "(No task goal registered — user-initiated or goal unknown)" : null,
    !hasUncommitted && !hasTrail ? "(No file changes or progress trail detected)" : null,
  ].filter(Boolean).join("\n");
  const metaSection = metaNotes ? `\n\n[Note: ${metaNotes}]` : "";

  contextParts.push(`[${sessionLabel(sessionType)} ${project}] [${mode}] Completion Output:\n\n${displayText}${metaSection}`);

  // Apply total message cap (tail-priority: completion output at the end is most important)
  const MAX_TOTAL_BODY_CHARS = 16000;
  let body = contextParts.join("\n\n---\n\n");
  if (body.length > MAX_TOTAL_BODY_CHARS) {
    body = capText(body, MAX_TOTAL_BODY_CHARS, "tail");
  }

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

  // Helper: send to LINE only when LINE is available
  const sendLine = async (conv, text) => {
    if (!lineAvailable) { log?.debug?.(`clawgate: [${accountId}] LINE skip (lineAvailable=false)`); return; }
    const result = await clawgateSend(apiUrl, conv, text, traceId);
    if (!result?.ok) {
      log?.warn?.(`clawgate: sendLine failed (completion): ${JSON.stringify(result?.error || result)}`);
    }
    recordPluginSend(text);
  };

  // Dispatch to AI — the AI will summarize and reply via LINE
  // In autonomous mode, parse <cc_task> tags and route tasks to Claude Code
  const deliver = async (replyPayload) => {
    const replyText = extractReplyText(replyPayload, log, "tmux_completion");
    if (!replyText.trim()) return;

    // Autonomous mode: try <cc_task> with round limiting (max 3 rounds)
    if (mode === "autonomous") {
      const rounds = questionRoundMap.get(project) || 0;
      const MAX_ROUNDS = 3;

      if (rounds < MAX_ROUNDS) {
        const result = await tryExtractAndSendTask({
          replyText, project, apiUrl, traceId, log, mode,
        });
        if (result) {
          if (result.error) {
            const msg = `[Task send failed: ${result.error.message || result.error}]\n\n${result.lineText}`;
            try { await sendLine(defaultConversation || project, msg); } catch (err) {
              log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
            }
          } else {
            questionRoundMap.set(project, rounds + 1);
            if (result.lineText) {
              const normalized = normalizeLineReplyText(result.lineText, { project, sessionType, eventKind: "completion" });
              try { await sendLine(defaultConversation || project, normalized); } catch (err) {
                log?.error?.(`clawgate: [${accountId}] send line text to LINE failed: ${err}`);
              }
            }
          }
          return;
        }
      }
      // No <cc_task> or max rounds reached — reset counter, fall through to LINE
      questionRoundMap.delete(project);
    }

    // Auto mode: try <cc_task> (no round limiting)
    if (mode === "auto") {
      const result = await tryExtractAndSendTask({
        replyText, project, apiUrl, traceId, log, mode,
      });
      if (result) {
        if (result.error) {
          const msg = `[Task send failed: ${result.error.message || result.error}]\n\n${result.lineText}`;
          try { await sendLine(defaultConversation || project, msg); } catch (err) {
            log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
          }
        } else {
          if (result.lineText) {
            const normalized = normalizeLineReplyText(result.lineText, { project, sessionType, eventKind: "completion" });
            try { await sendLine(defaultConversation || project, normalized); } catch (err) {
              log?.error?.(`clawgate: [${accountId}] send line text to LINE failed: ${err}`);
            }
          }
        }
        return;
      }
      // No <cc_task> found — fall through to normal delivery
    }

    // Default: forward all to LINE
    const lineText = normalizeLineReplyText(replyText, { project, sessionType, eventKind: "completion" });
    log?.info?.(`clawgate: [${accountId}] sending tmux result to LINE "${defaultConversation}": "${lineText.slice(0, 80)}"`);
    try {
      await sendLine(defaultConversation || project, lineText);
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send tmux result to LINE failed: ${err}`);
    }
  };

  // Register project context for outbound.sendText prefix fallback
  setActiveProject(defaultConversation || project, project, sessionType);

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

  // Detect LINE availability: explicit override from config, or auto-detect from ClawGate
  let lineAvailable = account.lineNotify !== undefined ? !!account.lineNotify : true;

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
      // Auto-detect LINE availability when not explicitly overridden
      if (account.lineNotify === undefined) {
        lineAvailable = !!remoteConfig.line.enabled;
      }
    }
    log?.info?.(`clawgate: [${accountId}] lineAvailable=${lineAvailable}`);
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

          // Handle tmux progress events — accumulate only, no AI dispatch or LINE send
          if (event.adapter === "tmux" && event.payload?.source === "progress") {
            const proj = event.payload.project;
            const progressText = event.payload.text || "";
            setProgressSnapshot(proj, progressText);
            appendProgressTrail(proj, progressText);
            sessionStatuses.set(proj, "running");
            continue;
          }

          // Handle tmux question events (AskUserQuestion)
          if (event.adapter === "tmux" && event.payload?.source === "question") {
            try {
              await handleTmuxQuestion({ event, accountId, apiUrl, cfg, defaultConversation, log, lineAvailable });
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
              await handleTmuxCompletion({ event, accountId, apiUrl, cfg, defaultConversation, log, lineAvailable });
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

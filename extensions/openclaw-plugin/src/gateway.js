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

import { readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join, dirname, isAbsolute } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolveAccount } from "./config.js";
import {
  clawgateHealth,
  clawgateDoctor,
  clawgateConfig,
  clawgateSend,
  clawgatePoll,
  clawgateTmuxSend,
  clawgateTmuxRead,
  setClawgateAuthToken,
} from "./client.js";
import { setActiveProject, getActiveProject, clearActiveProject } from "./shared-state.js";
import defaultPrompts from "./prompts.js";
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
  getProgressSnapshot,
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
import { createProjectViewReader } from "./project-view.js";

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

// ── Prompt loading with layered overlays ───────────────────────────
const DEFAULT_PRIVATE_PROMPTS_PATH = join(homedir(), ".clawgate", "prompts-private.js");
const PROMPT_PROFILE_VERSION = "2026-02-19.autonomous-policy-v1";
function envFlag(name, fallback = false) {
  const raw = `${process.env[name] ?? ""}`.trim();
  if (!raw) return fallback;
  return /^(1|true|yes|on)$/i.test(raw);
}
const ENABLE_INTERACTION_PENDING_STRICT_V2 = envFlag("CLAWGATE_INTERACTION_PENDING_STRICT_V2", true);
const ENABLE_AUTONOMOUS_LOOP_GUARD_V2 = envFlag("CLAWGATE_AUTONOMOUS_LOOP_GUARD_V2", true);
const ENABLE_INGRESS_DEDUP_TUNE_V2 = envFlag("CLAWGATE_INGRESS_DEDUP_TUNE_V2", true);
const OBSERVE_REQUIRED_TOKENS = ["goal", "scope", "risk", "3-8"];
const AUTONOMOUS_REQUIRED_TOKENS = ["<cc_task>"];
const AUTONOMOUS_FORBIDDEN_PROMPT_PATTERNS = [
  /^\s*見た[。.!]?\s*$/u,
  /^\s*確認(した|済み)?[。.!]?\s*$/u,
  /^\s*kickoff(?:\s+message)?[。.!]?\s*$/i,
  /^\s*autonomous review loop started.*$/i,
  /^\s*3[〜-]?5\s*文字[。.!]?\s*$/u,
  /^\s*3-5\s*chars?(?:\s+only)?[。.!]?\s*$/i,
  /^\s*one-word acknowledg(?:e|ement).*[。.!]?\s*$/i,
];
const AUTONOMOUS_SUPPRESSED_LINE_PATTERNS = [
  /^見た[。.!]?$/u,
  /^確認(した|済み)?[。.!]?$/u,
  /^了解[。.!]?$/u,
  /^ok[。.!]?$/i,
  /autonomous review loop started/i,
  /\[task send failed:/i,
  /i'?m discussing details directly in-session/i,
];
let _prompts = defaultPrompts;
let _promptsLoaded = false;
let _promptLoadSignature = "";
let _promptMeta = {
  version: PROMPT_PROFILE_VERSION,
  hash: "",
  layers: ["core:prompts.js"],
  validationEnabled: true,
  privateOverlayPath: "",
};

function normalizeOverlayPath(rawPath) {
  const candidate = `${rawPath || ""}`.trim();
  if (!candidate) return "";
  if (candidate.startsWith("~/")) {
    return join(homedir(), candidate.slice(2));
  }
  if (isAbsolute(candidate)) return candidate;
  return join(process.cwd(), candidate);
}

function resolvePromptOptions(accountConfig = {}) {
  const promptConfig = accountConfig?.prompts && typeof accountConfig.prompts === "object"
    ? accountConfig.prompts
    : {};
  const privateOverlayPath = normalizeOverlayPath(
    promptConfig.privateOverlayPath || process.env.CLAWGATE_PROMPTS_PRIVATE_PATH || DEFAULT_PRIVATE_PROMPTS_PATH
  );
  return {
    enableValidation: promptConfig.enableValidation !== false,
    enableRepoLocalOverlay: promptConfig.enableRepoLocalOverlay !== false,
    privateOverlayPath,
  };
}

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map((v) => stableStringify(v)).join(",")}]`;
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function promptHash(prompts) {
  return createHash("sha256").update(stableStringify(prompts)).digest("hex").slice(0, 16);
}

function asPromptLines(value) {
  if (Array.isArray(value)) return value.filter((item) => typeof item === "string");
  if (typeof value === "string") return [value];
  return [];
}

function linesIncludeTokens(lines, tokens) {
  const text = asPromptLines(lines).join("\n").toLowerCase();
  return tokens.every((token) => text.includes(token.toLowerCase()));
}

function containsForbiddenAutonomousPromptText(lines) {
  const text = asPromptLines(lines).join("\n");
  if (!text.trim()) return false;
  return AUTONOMOUS_FORBIDDEN_PROMPT_PATTERNS.some((pattern) => pattern.test(text));
}

function shouldSuppressAutonomousLine(text) {
  const normalized = `${text || ""}`.replace(/\s+/g, " ").trim();
  if (!normalized) return true;
  if (AUTONOMOUS_SUPPRESSED_LINE_PATTERNS.some((pattern) => pattern.test(normalized))) {
    return true;
  }
  // Very short acknowledgements are almost always noise in LINE autonomous flow.
  if (normalized.length <= 24 && /^(見た|確認(した|済み)?|了解|ok)[。.!]?$/iu.test(normalized)) {
    return true;
  }
  return false;
}

function validatePromptShape(prompts) {
  const errors = [];
  if (!Array.isArray(prompts?.firstTime) || prompts.firstTime.length === 0) {
    errors.push("firstTime must be a non-empty array");
  }
  if (typeof prompts?.completion?.header !== "string" || !prompts.completion.header.trim()) {
    errors.push("completion.header must be a non-empty string");
  }
  if (asPromptLines(prompts?.completion?.autonomous).length === 0) {
    errors.push("completion.autonomous must be a non-empty string/array");
  }
  if (asPromptLines(prompts?.completion?.observe).length === 0) {
    errors.push("completion.observe must be a non-empty string/array");
  }
  if (asPromptLines(prompts?.completion?.auto).length === 0) {
    errors.push("completion.auto must be a non-empty string/array");
  }
  if (typeof prompts?.completion?.noReply !== "string" || !prompts.completion.noReply.trim()) {
    errors.push("completion.noReply must be a non-empty string");
  }
  if (asPromptLines(prompts?.question?.auto).length === 0) {
    errors.push("question.auto must be a non-empty string/array");
  }
  if (asPromptLines(prompts?.question?.autonomous).length === 0) {
    errors.push("question.autonomous must be a non-empty string/array");
  }
  if (asPromptLines(prompts?.question?.observe).length === 0) {
    errors.push("question.observe must be a non-empty string/array");
  }
  if (typeof prompts?.question?.noReply !== "string" || !prompts.question.noReply.trim()) {
    errors.push("question.noReply must be a non-empty string");
  }
  if (typeof prompts?.questionBody?.auto !== "string" || !prompts.questionBody.auto.trim()) {
    errors.push("questionBody.auto must be a non-empty string");
  }
  if (typeof prompts?.questionBody?.default !== "string" || !prompts.questionBody.default.trim()) {
    errors.push("questionBody.default must be a non-empty string");
  }
  return errors;
}

function enforceCriticalPromptContracts(prompts) {
  const repaired = [];
  if (!linesIncludeTokens(prompts?.completion?.observe, OBSERVE_REQUIRED_TOKENS)) {
    prompts.completion.observe = structuredClone(defaultPrompts.completion.observe);
    repaired.push("completion.observe");
  }
  if (!linesIncludeTokens(prompts?.completion?.autonomous, AUTONOMOUS_REQUIRED_TOKENS)) {
    prompts.completion.autonomous = structuredClone(defaultPrompts.completion.autonomous);
    repaired.push("completion.autonomous");
  }
  if (containsForbiddenAutonomousPromptText(prompts?.completion?.autonomous)) {
    prompts.completion.autonomous = structuredClone(defaultPrompts.completion.autonomous);
    repaired.push("completion.autonomous(forbidden_chatter)");
  }
  if (containsForbiddenAutonomousPromptText(prompts?.firstTime)) {
    prompts.firstTime = structuredClone(defaultPrompts.firstTime);
    repaired.push("firstTime(forbidden_chatter)");
  }
  return repaired;
}

async function tryLoadOverlayFromPath(filePath, label, log) {
  if (!filePath || !existsSync(filePath)) return null;
  try {
    const moduleUrl = `${pathToFileURL(filePath).href}?v=${Date.now()}`;
    const mod = await import(moduleUrl);
    if (!mod?.default || typeof mod.default !== "object") {
      log?.warn?.(`clawgate: prompt overlay "${label}" has no default object export`);
      return null;
    }
    return mod.default;
  } catch (err) {
    log?.warn?.(`clawgate: failed to load prompt overlay "${label}": ${err.message || err}`);
    return null;
  }
}

async function loadPrompts(log, options = {}) {
  const resolved = {
    enableValidation: options.enableValidation !== false,
    enableRepoLocalOverlay: options.enableRepoLocalOverlay !== false,
    privateOverlayPath: normalizeOverlayPath(options.privateOverlayPath || DEFAULT_PRIVATE_PROMPTS_PATH),
  };
  const signature = stableStringify(resolved);
  if (_promptsLoaded) {
    if (_promptLoadSignature && _promptLoadSignature !== signature) {
      log?.warn?.("clawgate: prompts already loaded; ignoring different prompt options from another account");
    }
    return;
  }

  _promptsLoaded = true;
  _promptLoadSignature = signature;

  let merged = structuredClone(defaultPrompts);
  const layers = ["core:prompts.js"];

  if (resolved.enableRepoLocalOverlay) {
    const localPath = fileURLToPath(new URL("./prompts-local.js", import.meta.url));
    const localOverlay = await tryLoadOverlayFromPath(localPath, "repo:prompts-local.js", log);
    if (localOverlay) {
      merged = deepMerge(merged, localOverlay);
      layers.push("repo:prompts-local.js");
    }
  }

  const privateOverlay = await tryLoadOverlayFromPath(
    resolved.privateOverlayPath,
    `home:${resolved.privateOverlayPath}`,
    log
  );
  if (privateOverlay) {
    merged = deepMerge(merged, privateOverlay);
    layers.push("home:prompts-private.js");
  }

  if (resolved.enableValidation) {
    const errors = validatePromptShape(merged);
    if (errors.length > 0) {
      log?.error?.(`clawgate: prompt validation failed: ${errors.join("; ")} — using core prompts`);
      merged = structuredClone(defaultPrompts);
      layers.push("fallback:core");
    }
  }

  const repaired = enforceCriticalPromptContracts(merged);
  if (repaired.length > 0) {
    log?.warn?.(`clawgate: restored protected prompt sections from core: ${repaired.join(", ")}`);
  }

  _prompts = merged;
  _promptMeta = {
    version: PROMPT_PROFILE_VERSION,
    hash: promptHash(_prompts),
    layers,
    validationEnabled: resolved.enableValidation,
    privateOverlayPath: resolved.privateOverlayPath,
  };
  log?.info?.(`clawgate: prompts loaded version=${_promptMeta.version} hash=${_promptMeta.hash} layers=${layers.join(" -> ")}`);
}

function deepMerge(base, overlay) {
  if (!overlay || typeof overlay !== "object" || Array.isArray(overlay)) return overlay ?? base;
  if (typeof base !== "object" || Array.isArray(base)) return overlay;
  const result = { ...base };
  for (const key of Object.keys(overlay)) {
    if (
      key in result &&
      typeof result[key] === "object" && !Array.isArray(result[key]) &&
      typeof overlay[key] === "object" && !Array.isArray(overlay[key])
    ) {
      result[key] = deepMerge(result[key], overlay[key]);
    } else {
      result[key] = overlay[key];
    }
  }
  return result;
}

function fillTemplate(str, vars) {
  let result = str;
  for (const [key, value] of Object.entries(vars)) {
    result = result.replaceAll(`{${key}}`, value);
  }
  return result;
}

function fillTemplateLines(lines, vars) {
  return lines.map((l) => fillTemplate(l, vars));
}

// ── Configurable display name filter (replaces hardcoded "Test User") ──
let _filterDisplayName = "";

// ── Session state tracking (for roster) ──────────────────────────
/** @type {Map<string, string>} project -> mode */
const sessionModes = new Map();
/** @type {Map<string, string>} project -> status */
const sessionStatuses = new Map();
/** @type {Map<string, { getContextBlock: Function }>} accountId -> read-only project-view reader */
const projectViewReaders = new Map();

// ── Pairing guidance dedup (full guidance sent once per project) ──
/** @type {Set<string>} */
const guidanceSentProjects = new Set();

// ── Autonomous conversation round tracking ──────────────────────
// Tracks how many completion->question rounds the reviewer agent has had with CC per project.
// Reset on question events, incremented on completion when the reviewer agent sends <cc_task>.
/** @type {Map<string, number>} project -> round count */
const questionRoundMap = new Map();
/** @type {Map<string, { active: boolean }>} project -> autonomous loop state */
const autonomousLoopState = new Map();
// ── Review-done suppression ─────────────────────────────────────
// After LGTM terminates the review loop, mark the project as "review-done".
// Completion events are skipped until a new task is sent or a question arrives.
// Safety valve: auto-clear stale review-done marks after a timeout.
const REVIEW_DONE_TTL_MS = 15 * 60 * 1000;
/** @type {Map<string, { setAt: number, reason: string }>} */
const reviewDoneProjects = new Map();
const AUTONOMOUS_RISK_PATTERNS = [
  /blocking/i,
  /regression/i,
  /breaking api/i,
  /data loss/i,
  /security/i,
  /crash/i,
  /fatal/i,
  /untested/i,
  /missing error handling/i,
  /重大/u,
  /危険/u,
  /破壊/u,
  /壊/u,
];

function getProjectViewReader(accountId, log) {
  const reader = projectViewReaders.get(accountId);
  if (reader) return reader;
  const fallback = createProjectViewReader({ enabled: false }, log);
  projectViewReaders.set(accountId, fallback);
  return fallback;
}

function joinSections(parts) {
  return (parts || []).filter(Boolean).join("\n\n---\n\n");
}

function buildPrioritizedBody({ requiredParts = [], optionalParts = [], maxChars = 16000, log, scope = "" }) {
  const required = joinSections(requiredParts);
  if (!required) {
    return capText(joinSections(optionalParts), maxChars, "tail");
  }

  if (required.length >= maxChars) {
    log?.warn?.(`clawgate: ${scope} required context exceeded ${maxChars} chars; truncating required segment`);
    return capText(required, maxChars, "tail");
  }

  const separator = "\n\n---\n\n";
  const optionalBudget = Math.max(0, maxChars - required.length - separator.length);
  let optional = joinSections(optionalParts);
  if (optionalBudget <= 0) return required;
  if (optional && optional.length > optionalBudget) {
    optional = capText(optional, optionalBudget, "tail");
  }
  return optional ? `${optional}${separator}${required}` : required;
}

function summarizeForLine(text, maxChars = 220) {
  const normalized = `${text || ""}`.replace(/\s+/g, " ").trim();
  if (!normalized) return "";
  if (normalized.length <= maxChars) return normalized;
  return `${normalized.slice(0, maxChars - 3)}...`;
}

function hasAutonomousRiskSignal(...chunks) {
  const text = chunks
    .map((chunk) => `${chunk || ""}`.trim())
    .filter(Boolean)
    .join("\n");
  if (!text) return false;
  return AUTONOMOUS_RISK_PATTERNS.some((pattern) => pattern.test(text));
}

function setAutonomousLoopActive(project, active) {
  if (!project) return;
  if (!active) {
    autonomousLoopState.delete(project);
    return;
  }
  autonomousLoopState.set(project, { active: true });
}

function setReviewDone(project, reason = "unknown") {
  if (!project) return;
  reviewDoneProjects.set(project, { setAt: Date.now(), reason });
}

function clearReviewDone(project) {
  if (!project) return false;
  return reviewDoneProjects.delete(project);
}

function getReviewDone(project) {
  const state = reviewDoneProjects.get(project);
  if (!state) return null;
  if (Date.now() - state.setAt > REVIEW_DONE_TTL_MS) {
    reviewDoneProjects.delete(project);
    return null;
  }
  return state;
}

function autonomousMilestoneLine({ reason, round, maxRounds, taskText, lineText }) {
  if (reason === "risk") {
    const riskSummary = summarizeForLine(lineText || taskText || "");
    return `Autonomous review found a potential risk at round ${round}/${maxRounds}.\n${riskSummary || "I flagged this in-session and will send final status after verification."}`;
  }
  return "";
}

function logAutonomousLineEvent(log, { accountId, project, reason, status, detail = "" }) {
  const promptHash = _promptMeta.hash || "unknown";
  const suffix = detail ? ` ${detail}` : "";
  log?.info?.(`clawgate: [${accountId}] autonomous_line reason=${reason} status=${status} project=${project} prompt=${promptHash}${suffix}`);
}

function eventTimestamp(event) {
  const raw = event?.observed_at ?? event?.observedAt;
  if (!raw) return Date.now();
  const parsed = Date.parse(raw);
  return Number.isNaN(parsed) ? Date.now() : parsed;
}

// ── Completion / task-send loop guards ─────────────────────────
const COMPLETION_DISPATCH_DEDUP_WINDOW_MS = 30_000;
const TASK_SEND_ERROR_NOTIFY_WINDOW_MS = 60_000;
const TASK_SEND_ESCALATION_WINDOW_MS = Math.max(
  5_000,
  (Number.parseInt(process.env.CLAWGATE_TASK_SEND_ESCALATION_SEC || "60", 10) || 60) * 1000
);
const INTERACTION_PENDING_NOTIFY_WINDOW_MS = Math.max(
  5_000,
  (Number.parseInt(process.env.CLAWGATE_INTERACTION_PENDING_NOTIFY_SEC || "60", 10) || 60) * 1000
);
const TMUX_TYPING_GUARD_READ_LINES = 120;
const TMUX_TYPING_GUARD_SCAN_TAIL_LINES = 48;
const TMUX_TYPING_GUARD_MAX_PROMPT_DISTANCE_LINES = 8;
const TMUX_TYPING_GUARD_MAX_CONTINUATION_LINES = 2;
const TMUX_PROMPT_LINE_RE = /^\s*[›❯>]\s*/u;
const ENABLE_DEBUG_TASK_FAILURE_CONTEXT = /^(1|true|yes)$/i.test(
  `${process.env.CLAWGATE_DEBUG_TASK_FAILURE_CONTEXT || process.env.CLAWGATE_DEBUG_FAILURE_CONTEXT || ""}`.trim()
);
/** @type {Map<string, number>} */
const recentCompletionDispatches = new Map();
/** @type {Map<string, number>} */
const recentTaskSendErrors = new Map();
/** @type {Map<string, { firstAt: number, lastAt: number, lastEscalatedAt: number, count: number, category: string }>} */
const taskSendFailureStreaks = new Map();
/** @type {Map<string, number>} */
const recentInteractionPendingNotifications = new Map();
/** @type {Map<string, { key: string, project: string, targetProject: string, taskText: string, prefixedTask: string, mode: string, traceId: string, createdAt: number, lastQueuedAt: number, retryCount: number }>} */
const pendingTaskQueue = new Map();
const TASK_QUEUE_TTL_MS = Math.max(
  10_000,
  (Number.parseInt(process.env.CLAWGATE_TASK_QUEUE_TTL_MS || "600000", 10) || 600000)
);
const TASK_QUEUE_MAX_GLOBAL = Math.max(
  10,
  (Number.parseInt(process.env.CLAWGATE_TASK_QUEUE_MAX_GLOBAL || "100", 10) || 100)
);
const TASK_QUEUE_MAX_PER_PROJECT = Math.max(
  1,
  (Number.parseInt(process.env.CLAWGATE_TASK_QUEUE_MAX_PER_PROJECT || "3", 10) || 3)
);

function normalizeFingerprintText(text, max = 800) {
  const normalized = `${text || ""}`.replace(/\s+/g, " ").trim();
  if (!normalized) return "";
  if (normalized.length <= max) return normalized;
  return normalized.slice(0, max);
}

function hashFingerprint(text) {
  return createHash("sha1").update(text).digest("hex");
}

function buildPendingTaskKey(targetProject, taskText) {
  const normalizedProject = `${targetProject || "unknown"}`.trim().toLowerCase();
  const normalizedTask = normalizeFingerprintText(taskText, 400);
  const hash = hashFingerprint(`${normalizedProject}::${normalizedTask}`);
  return `${normalizedProject}::${hash}`;
}

function queueProjectSize(project) {
  const normalizedProject = `${project || ""}`.trim();
  if (!normalizedProject) return 0;
  let count = 0;
  for (const item of pendingTaskQueue.values()) {
    if (item.targetProject === normalizedProject) count += 1;
  }
  return count;
}

function queueOldest(predicate = null) {
  /** @type {{key: string, createdAt: number} | null} */
  let oldest = null;
  for (const [key, item] of pendingTaskQueue) {
    if (predicate && !predicate(item)) continue;
    if (!oldest || item.createdAt < oldest.createdAt) {
      oldest = { key, createdAt: item.createdAt };
    }
  }
  return oldest?.key || null;
}

function prunePendingTaskQueue(log, now = Date.now()) {
  for (const [key, item] of pendingTaskQueue) {
    if (now - item.createdAt > TASK_QUEUE_TTL_MS) {
      pendingTaskQueue.delete(key);
      log?.info?.(
        `clawgate: task_queue_dropped_stale project=${item.targetProject} age_ms=${now - item.createdAt}`
      );
    }
  }

  while (pendingTaskQueue.size > TASK_QUEUE_MAX_GLOBAL) {
    const oldestKey = queueOldest();
    if (!oldestKey) break;
    const dropped = pendingTaskQueue.get(oldestKey);
    pendingTaskQueue.delete(oldestKey);
    if (dropped) {
      log?.info?.(
        `clawgate: task_queue_dropped_overflow scope=global project=${dropped.targetProject} key=${dropped.key.slice(0, 18)}`
      );
    }
  }
}

function enqueuePendingTask({
  project,
  targetProject,
  taskText,
  prefixedTask,
  mode,
  traceId,
  log,
}) {
  const now = Date.now();
  prunePendingTaskQueue(log, now);
  const key = buildPendingTaskKey(targetProject, taskText);
  const existing = pendingTaskQueue.get(key);
  if (existing) {
    existing.lastQueuedAt = now;
    pendingTaskQueue.set(key, existing);
    log?.info?.(
      `clawgate: task_queue_enqueued project=${targetProject} key=${key.slice(0, 18)} dedup=1 size=${pendingTaskQueue.size}`
    );
    return { queued: true, dedup: true, key };
  }

  while (queueProjectSize(targetProject) >= TASK_QUEUE_MAX_PER_PROJECT) {
    const oldestProjectKey = queueOldest((item) => item.targetProject === targetProject);
    if (!oldestProjectKey) break;
    const dropped = pendingTaskQueue.get(oldestProjectKey);
    pendingTaskQueue.delete(oldestProjectKey);
    if (dropped) {
      log?.info?.(
        `clawgate: task_queue_dropped_overflow scope=project project=${targetProject} key=${dropped.key.slice(0, 18)}`
      );
    }
  }

  pendingTaskQueue.set(key, {
    key,
    project,
    targetProject,
    taskText,
    prefixedTask,
    mode,
    traceId,
    createdAt: now,
    lastQueuedAt: now,
    retryCount: 0,
  });
  prunePendingTaskQueue(log, now);
  log?.info?.(
    `clawgate: task_queue_enqueued project=${targetProject} key=${key.slice(0, 18)} dedup=0 size=${pendingTaskQueue.size}`
  );
  return { queued: true, dedup: false, key };
}

async function flushPendingTaskQueue({
  apiUrl,
  traceId,
  log,
  resolveMode = (targetProject) => sessionModes.get(targetProject) || "ignore",
}) {
  if (pendingTaskQueue.size === 0) return;
  const now = Date.now();
  prunePendingTaskQueue(log, now);
  if (pendingTaskQueue.size === 0) return;

  const items = [...pendingTaskQueue.values()].sort((a, b) => a.createdAt - b.createdAt);
  for (const item of items) {
    const mode = `${resolveMode(item.targetProject) || "ignore"}`.toLowerCase();
    if (mode !== "autonomous" && mode !== "auto") {
      pendingTaskQueue.delete(item.key);
      log?.info?.(
        `clawgate: task_queue_dropped_mode project=${item.targetProject} mode=${mode} key=${item.key.slice(0, 18)}`
      );
      continue;
    }

    const interactionPending = getInteractionPending(item.targetProject);
    if (interactionPending) {
      continue;
    }

    const typingGuard = await inspectTmuxDraftBeforeTaskSend({
      apiUrl,
      project: item.targetProject,
      traceId: traceId || item.traceId,
      log,
    });
    if (typingGuard.blocked) {
      if (typingGuard.reason === "draft_detected") {
        continue;
      }
      // Unknown prompt state: don't block forwarding forever. Try actual tmux send path.
      log?.warn?.(
        `clawgate: task_queue typing-guard bypass project=${item.targetProject} reason=${typingGuard.reason}`
      );
    }

    try {
      const result = await clawgateTmuxSend(
        apiUrl,
        item.targetProject,
        item.prefixedTask,
        traceId || item.traceId
      );
      if (result?.ok) {
        pendingTaskQueue.delete(item.key);
        clearTaskSendFailureStreak(item.targetProject);
        setTaskGoal(item.targetProject, item.taskText);
        if (clearReviewDone(item.targetProject)) {
          log?.info?.(
            `clawgate: review-done CLEARED for "${item.targetProject}" — queued task sent, completions resumed`
          );
        }
        log?.info?.(
          `clawgate: task_queue_flushed project=${item.targetProject} key=${item.key.slice(0, 18)} age_ms=${Date.now() - item.createdAt}`
        );
        continue;
      }

      const errCode = `${result?.error?.code || ""}`.toLowerCase();
      if (errCode === "session_busy" || errCode === "session_not_found") {
        item.retryCount += 1;
        pendingTaskQueue.set(item.key, item);
        continue;
      }

      pendingTaskQueue.delete(item.key);
      log?.info?.(
        `clawgate: task_queue_dropped_send_failed project=${item.targetProject} code=${errCode || "unknown"} key=${item.key.slice(0, 18)}`
      );
    } catch (err) {
      const errMsg = `${err?.message || err || ""}`.toLowerCase();
      if (errMsg.includes("currently running") || errMsg.includes("session busy")) {
        item.retryCount += 1;
        pendingTaskQueue.set(item.key, item);
        continue;
      }
      pendingTaskQueue.delete(item.key);
      log?.info?.(
        `clawgate: task_queue_dropped_exception project=${item.targetProject} key=${item.key.slice(0, 18)}`
      );
    }
  }
}

function shouldSkipCompletionDispatch({ project, mode, sessionType, text }) {
  const now = Date.now();
  for (const [k, ts] of recentCompletionDispatches) {
    if (now - ts > COMPLETION_DISPATCH_DEDUP_WINDOW_MS) recentCompletionDispatches.delete(k);
  }

  const normalized = normalizeFingerprintText(text, 1200);
  const keyMaterial = `${project}::${mode}::${sessionType}::${normalized}`;
  const key = hashFingerprint(keyMaterial);
  const last = recentCompletionDispatches.get(key);
  if (last && now - last <= COMPLETION_DISPATCH_DEDUP_WINDOW_MS) {
    return true;
  }
  recentCompletionDispatches.set(key, now);
  return false;
}

function shouldNotifyTaskSendError({ project, errorCode, taskText }) {
  const now = Date.now();
  for (const [k, ts] of recentTaskSendErrors) {
    if (now - ts > TASK_SEND_ERROR_NOTIFY_WINDOW_MS) recentTaskSendErrors.delete(k);
  }

  const normalizedCode = `${errorCode || "unknown"}`.toLowerCase();
  const normalizedTask = normalizeFingerprintText(taskText, 240);
  const keyMaterial = normalizedCode === "session_typing_busy"
    ? `${project || "unknown"}::${normalizedCode}`
    : `${project || "unknown"}::${normalizedCode}::${normalizedTask}`;
  const key = hashFingerprint(keyMaterial);
  const last = recentTaskSendErrors.get(key);
  if (last && now - last <= TASK_SEND_ERROR_NOTIFY_WINDOW_MS) {
    return false;
  }
  recentTaskSendErrors.set(key, now);
  return true;
}

function shouldNotifyInteractionPending({
  project,
  reason,
  questionText,
  options = [],
}) {
  if (!ENABLE_AUTONOMOUS_LOOP_GUARD_V2) return true;
  const now = Date.now();
  for (const [k, ts] of recentInteractionPendingNotifications) {
    if (now - ts > INTERACTION_PENDING_NOTIFY_WINDOW_MS) recentInteractionPendingNotifications.delete(k);
  }
  const normalizedQuestion = normalizeFingerprintText(questionText, 400);
  const normalizedOptions = Array.isArray(options)
    ? options.map((opt) => normalizeFingerprintText(opt, 120)).join("|")
    : "";
  const keyMaterial = `${project || "unknown"}::${reason || "interaction_pending"}::${normalizedQuestion}::${normalizedOptions}`;
  const key = hashFingerprint(keyMaterial);
  const last = recentInteractionPendingNotifications.get(key);
  if (last && now - last <= INTERACTION_PENDING_NOTIFY_WINDOW_MS) {
    return false;
  }
  recentInteractionPendingNotifications.set(key, now);
  return true;
}

function classifyTaskSendFailure({ errorCode, errorMessage }) {
  const code = `${errorCode || ""}`.toLowerCase();
  const message = `${errorMessage || ""}`.toLowerCase();

  if (
    code === "session_typing_busy" ||
    message.includes("unsent input") ||
    message.includes("prompt state is unknown")
  ) {
    return "typing_busy";
  }
  if (code === "session_busy" || message.includes("currently running") || message.includes("session busy")) {
    return "busy";
  }
  if (
    code === "session_read_only" ||
    message.includes("read-only") ||
    message.includes("task send disabled")
  ) {
    return "readonly";
  }
  if (
    code === "aborterror" ||
    code === "aborted" ||
    message.includes("operation was aborted") ||
    message.includes("was aborted")
  ) {
    return "aborted";
  }
  if (
    code === "interaction_pending" ||
    message.includes("waiting for user interaction")
  ) {
    return "interaction_pending";
  }
  return "other";
}

function trackTaskSendFailureStreak({ project, category }) {
  const key = `${project || "unknown"}::${category}`;
  const now = Date.now();
  const existing = taskSendFailureStreaks.get(key);
  const stale = !existing || now - existing.lastAt > TASK_SEND_ESCALATION_WINDOW_MS;
  const firstAt = stale ? now : existing.firstAt;
  const count = stale ? 1 : (existing.count + 1);
  const next = {
    firstAt,
    lastAt: now,
    lastEscalatedAt: existing?.lastEscalatedAt || 0,
    count,
    category,
  };

  const streakDurationMs = now - firstAt;
  const shouldEscalate =
    streakDurationMs >= TASK_SEND_ESCALATION_WINDOW_MS &&
    (next.lastEscalatedAt === 0 || now - next.lastEscalatedAt >= TASK_SEND_ESCALATION_WINDOW_MS);
  if (shouldEscalate) {
    next.lastEscalatedAt = now;
  }

  taskSendFailureStreaks.set(key, next);
  return {
    shouldEscalate,
    streakDurationMs,
    count,
  };
}

function clearTaskSendFailureStreak(project) {
  const prefix = `${project || "unknown"}::`;
  for (const key of taskSendFailureStreaks.keys()) {
    if (key.startsWith(prefix)) {
      taskSendFailureStreaks.delete(key);
    }
  }
}

function buildTaskFailureEscalationLine({ project, category, streakDurationMs }) {
  const seconds = Math.max(1, Math.round(streakDurationMs / 1000));
  if (category === "typing_busy") {
    return `Autonomous relay for ${project} is paused while terminal input is being edited (${seconds}s). I will retry after input settles.`;
  }
  if (category === "busy") {
    return `Autonomous relay for ${project} is busy (${seconds}s). I’ll keep retrying and send only meaningful updates.`;
  }
  if (category === "readonly") {
    return `Autonomous relay for ${project} is blocked by session mode (${seconds}s). I’ll keep monitoring and report when routing resumes.`;
  }
  if (category === "aborted") {
    return `Autonomous relay for ${project} is being aborted repeatedly (${seconds}s). I’ll continue retrying and report recovery.`;
  }
  if (category === "interaction_pending") {
    return `Autonomous relay for ${project} is paused for a terminal choice (${seconds}s). Please answer the prompt in-session.`;
  }
  return `Autonomous relay for ${project} is unstable (${seconds}s). I’ll keep monitoring and report recovery.`;
}

function buildTypingBusyAdvisoryLine(project) {
  return `Paused autonomous task send for ${project}: unsent text is detected in the terminal input. I will resume after you finish typing.`;
}

// ── Plugin-level echo suppression ──────────────────────────────
// ClawGate's RecentSendTracker uses an 8-second window which is too short
// for AI replies (typically 10-30s). We maintain a secondary tracker here.

const ECHO_WINDOW_MS = 600_000; // 10 minutes — covers delayed re-render of Chi's replies
const COOLDOWN_MS = 5_000;     // retained for metrics/log context (no blanket drop)

/** @type {{ text: string, time: number }[]} */
const recentSends = [];
let lastSendTime = 0;

function recordPluginSend(text) {
  const now = Date.now();
  lastSendTime = now;
  recentSends.push({ text: text.trim(), time: now });
  console.debug(`[outbound_recorded] text_head="${text.slice(0, 40)}" ts=${now} echo_window_ms=${ECHO_WINDOW_MS}`);
  // Prune old entries
  const cutoff = now - ECHO_WINDOW_MS;
  while (recentSends.length > 0 && recentSends[0].time < cutoff) {
    recentSends.shift();
  }
}

/**
 * Check if event text looks like an echo of a recently sent message.
 * Uses substring matching since OCR text may be noisy/truncated.
 */
function normalizeEchoText(text) {
  return `${text || ""}`.toLowerCase().replace(/\s+/g, " ").trim();
}

function isLikelyPluginEcho(candidate, sent) {
  const normalizedCandidate = normalizeEchoText(candidate);
  const normalizedSent = normalizeEchoText(sent);
  if (!normalizedCandidate || !normalizedSent) return false;
  if (normalizedCandidate === normalizedSent) return normalizedCandidate.length >= 2;
  if (Math.min(normalizedCandidate.length, normalizedSent.length) < 6) return false;
  if (normalizedCandidate.includes(normalizedSent)) {
    const dominance = normalizedSent.length / Math.max(normalizedCandidate.length, 1);
    return dominance >= 0.70;
  }
  if (normalizedSent.includes(normalizedCandidate)) {
    const coverage = normalizedCandidate.length / Math.max(normalizedSent.length, 1);
    return coverage >= 0.85;
  }
  return false;
}

function isLikelyPluginEchoByLines(candidate, sends) {
  const lines = `${candidate || ""}`
    .split("\n")
    .map((line) => normalizeEchoText(line))
    .filter((line) => line.length >= 6);
  if (lines.length < 2) return false;

  let matched = 0;
  for (const line of lines) {
    const hit = sends.some((s) => isLikelyPluginEcho(line, s.text));
    if (hit) matched += 1;
  }
  if (matched >= 2) return true;
  return (matched / lines.length) >= 0.6;
}

function isPluginEcho(eventText) {
  if (!eventText) return false;
  const now = Date.now();
  const cutoff = now - ECHO_WINDOW_MS;
  const normalizedEvent = eventText.replace(/\s+/g, " ").trim();
  const inCooldown = (now - lastSendTime) < COOLDOWN_MS;

  for (const s of recentSends) {
    if (s.time < cutoff) continue;
    if (inCooldown && ENABLE_INGRESS_DEDUP_TUNE_V2) {
      // For very short, immediate echoes, allow only strict-match suppression.
      const a = normalizeEchoText(normalizedEvent).replace(/\s+/g, "");
      const b = normalizeEchoText(s.text).replace(/\s+/g, "");
      if (a.length >= 2 && a === b) {
        return true;
      }
    }
    if (ENABLE_INGRESS_DEDUP_TUNE_V2) {
      if (isLikelyPluginEcho(normalizedEvent, s.text)) {
        return true;
      }
      continue;
    }
    // Legacy behavior: prefix substring match
    const sentSnippet = s.text.slice(0, 40).replace(/\s+/g, " ");
    if (sentSnippet.length >= 8 && normalizedEvent.includes(sentSnippet)) {
      return true;
    }
  }
  if (ENABLE_INGRESS_DEDUP_TUNE_V2) {
    const activeSends = recentSends.filter((s) => s.time >= cutoff);
    if (isLikelyPluginEchoByLines(eventText, activeSends)) {
      return true;
    }
  }
  // Log echo guard miss so we can diagnose re-delivered messages that bypass the guard
  const lastSendAge = recentSends.length ? now - recentSends[recentSends.length - 1].time : -1;
  const activeSendCount = recentSends.filter((s) => s.time >= cutoff).length;
  if (activeSendCount > 0) {
    // Only log when there were candidates (miss is interesting, not "no sends recorded")
    console.debug(`[echo_guard_miss] text_head="${eventText.slice(0, 40)}" active_sends=${activeSendCount} last_send_age_ms=${lastSendAge}`);
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
const DEDUP_WINDOW_MS_V2 = Math.max(
  0,
  (Number.parseInt(process.env.CLAWGATE_INGRESS_DEDUP_WINDOW_MS || "8000", 10) || 8000)
);
const STALE_REPEAT_WINDOW_MS_V2 = Math.max(
  0,
  (Number.parseInt(process.env.CLAWGATE_INGRESS_STALE_REPEAT_WINDOW_MS || "20000", 10) || 20000)
);
const ENABLE_COMMON_INGRESS_DEDUP = envFlag("CLAWGATE_COMMON_INGRESS_DEDUP", true);
const COMMON_INGRESS_DEDUP_WINDOW_MS = Math.max(
  5_000,
  (Number.parseInt(process.env.CLAWGATE_COMMON_INGRESS_DEDUP_WINDOW_MS || "20000", 10) || 20000)
);
const COMMON_INGRESS_DEDUP_MAX_ENTRIES = Math.max(
  200,
  (Number.parseInt(process.env.CLAWGATE_COMMON_INGRESS_DEDUP_MAX_ENTRIES || "2000", 10) || 2000)
);
const ENABLE_SHORT_LINE_DEDUP = envFlag("CLAWGATE_SHORT_LINE_DEDUP", true);
const SHORT_LINE_DEDUP_WINDOW_MS = Math.max(
  3_000,
  (Number.parseInt(process.env.CLAWGATE_SHORT_LINE_DEDUP_WINDOW_MS || "25000", 10) || 25000)
);
const SHORT_LINE_MAX_CHARS = Math.max(
  2,
  (Number.parseInt(process.env.CLAWGATE_SHORT_LINE_MAX_CHARS || "24", 10) || 24)
);
const ENABLE_LINE_BURST_COALESCE = envFlag("CLAWGATE_LINE_BURST_COALESCE", true);
const LINE_BURST_COALESCE_WINDOW_MS = Math.max(
  0,
  (Number.parseInt(process.env.CLAWGATE_LINE_BURST_COALESCE_WINDOW_MS || "1500", 10) || 1500)
);
const LINE_BURST_MAX_SEGMENTS = Math.max(
  4,
  (Number.parseInt(process.env.CLAWGATE_LINE_BURST_MAX_SEGMENTS || "36", 10) || 36)
);

/** @type {{ fingerprint: string, time: number }[]} */
const recentInbounds = [];
/** @type {{ key: string, time: number }[]} */
const recentStableInbounds = [];
/** @type {{ keyHash: string, compact: string, time: number }[]} */
const recentCommonInbounds = [];
/** @type {{ keyHash: string, compact: string, time: number }[]} */
const recentShortLineInbounds = [];

function eventFingerprint(text) {
  return text.replace(/\s+/g, " ").trim().slice(0, 60);
}

function dedupTextHead(text, maxChars = 80) {
  return `${text || ""}`.replace(/\s+/g, " ").trim().slice(0, maxChars);
}

function activeDedupWindowMs() {
  return ENABLE_INGRESS_DEDUP_TUNE_V2 ? DEDUP_WINDOW_MS_V2 : DEDUP_WINDOW_MS;
}

function activeStaleRepeatWindowMs() {
  return ENABLE_INGRESS_DEDUP_TUNE_V2 ? STALE_REPEAT_WINDOW_MS_V2 : STALE_REPEAT_WINDOW_MS;
}

function isDuplicateInbound(eventText) {
  const windowMs = activeDedupWindowMs();
  if (windowMs <= 0) return false;
  const now = Date.now();
  // Prune expired entries
  while (recentInbounds.length > 0 && recentInbounds[0].time < now - windowMs) {
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

function normalizeCommonDedupText(rawText) {
  const normalized = `${rawText || ""}`
    .normalize("NFKC")
    .replace(/\[tproj-msg:[^\]]*\]\s*/giu, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  if (!normalized) return { normalized: "", compact: "" };
  const compact = normalized
    .replace(/[\p{P}\p{S}\s_]+/gu, "")
    .slice(0, 400);
  return { normalized, compact };
}

function buildCommonIngressDedupKey({ adapter, conversation, eventText }) {
  const normalizedAdapter = `${adapter || "unknown"}`
    .trim()
    .toLowerCase();
  const normalizedConversation = `${conversation || ""}`
    .normalize("NFKC")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  const { compact } = normalizeCommonDedupText(eventText);
  if (compact.length < 10) {
    return { enabled: false, keyHash: "", compact: "" };
  }
  const material = `${normalizedAdapter}::${normalizedConversation}::${compact}`;
  return {
    enabled: true,
    keyHash: hashFingerprint(material),
    compact,
  };
}

function compactSimilarityScore(a, b) {
  if (!a || !b) return 0;
  if (a === b) return 1;

  const short = a.length <= b.length ? a : b;
  const long = a.length <= b.length ? b : a;
  if (short.length >= 12 && long.includes(short)) {
    return short.length / Math.max(long.length, 1);
  }

  if (a.length < 3 || b.length < 3) return 0;
  const gramsA = new Set();
  const gramsB = new Set();
  for (let i = 0; i <= a.length - 3; i += 1) gramsA.add(a.slice(i, i + 3));
  for (let i = 0; i <= b.length - 3; i += 1) gramsB.add(b.slice(i, i + 3));
  if (gramsA.size === 0 || gramsB.size === 0) return 0;
  let inter = 0;
  for (const g of gramsA) {
    if (gramsB.has(g)) inter += 1;
  }
  return (2 * inter) / (gramsA.size + gramsB.size);
}

function pruneCommonIngressDedup(now = Date.now()) {
  const cutoff = now - COMMON_INGRESS_DEDUP_WINDOW_MS;
  while (recentCommonInbounds.length > 0 && recentCommonInbounds[0].time < cutoff) {
    recentCommonInbounds.shift();
  }
  if (recentCommonInbounds.length > COMMON_INGRESS_DEDUP_MAX_ENTRIES) {
    recentCommonInbounds.splice(0, recentCommonInbounds.length - COMMON_INGRESS_DEDUP_MAX_ENTRIES);
  }
}

function matchCommonIngressDuplicate(commonKey) {
  if (!ENABLE_COMMON_INGRESS_DEDUP || !commonKey?.enabled) {
    return { hit: false, reason: "disabled" };
  }
  const now = Date.now();
  pruneCommonIngressDedup(now);

  const exact = recentCommonInbounds.find((entry) => entry.keyHash === commonKey.keyHash);
  if (exact) {
    return { hit: true, reason: "exact_key", matchedKeyHash: exact.keyHash };
  }

  const near = recentCommonInbounds.find((entry) => {
    const score = compactSimilarityScore(commonKey.compact, entry.compact);
    return score >= 0.93;
  });
  if (near) {
    return { hit: true, reason: "near_compact", matchedKeyHash: near.keyHash };
  }
  return { hit: false, reason: "none" };
}

function recordCommonIngress(commonKey) {
  if (!ENABLE_COMMON_INGRESS_DEDUP || !commonKey?.enabled) return;
  const now = Date.now();
  pruneCommonIngressDedup(now);
  recentCommonInbounds.push({
    keyHash: commonKey.keyHash,
    compact: commonKey.compact,
    time: now,
  });
}

function normalizeShortLineDedupText(rawText) {
  return `${rawText || ""}`
    .normalize("NFKC")
    .toLowerCase()
    .replace(/\s+/g, "")
    .replace(/[\p{P}\p{S}_]+/gu, "")
    .trim();
}

function buildShortLineIngressDedupKey({ adapter, conversation, eventText, source }) {
  if (!ENABLE_SHORT_LINE_DEDUP) {
    return { enabled: false, keyHash: "", compact: "" };
  }
  const normalizedAdapter = `${adapter || "unknown"}`.trim().toLowerCase();
  const normalizedSource = `${source || "poll"}`.trim().toLowerCase();
  if (normalizedAdapter !== "line") {
    return { enabled: false, keyHash: "", compact: "" };
  }
  if (normalizedSource === "notification_banner") {
    return { enabled: false, keyHash: "", compact: "" };
  }
  if (`${eventText || ""}`.includes("\n")) {
    return { enabled: false, keyHash: "", compact: "" };
  }
  const compact = normalizeShortLineDedupText(eventText);
  if (compact.length < 2 || compact.length > SHORT_LINE_MAX_CHARS) {
    return { enabled: false, keyHash: "", compact };
  }
  const normalizedConversation = `${conversation || ""}`
    .normalize("NFKC")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  const material = `${normalizedAdapter}::${normalizedConversation}::${compact}`;
  return {
    enabled: true,
    keyHash: hashFingerprint(material),
    compact,
  };
}

function pruneShortLineIngressDedup(now = Date.now()) {
  const cutoff = now - SHORT_LINE_DEDUP_WINDOW_MS;
  while (recentShortLineInbounds.length > 0 && recentShortLineInbounds[0].time < cutoff) {
    recentShortLineInbounds.shift();
  }
}

function matchShortLineIngressDuplicate(shortKey) {
  if (!ENABLE_SHORT_LINE_DEDUP || !shortKey?.enabled) {
    return { hit: false, reason: "disabled" };
  }
  const now = Date.now();
  pruneShortLineIngressDedup(now);
  const exact = recentShortLineInbounds.find((entry) => entry.keyHash === shortKey.keyHash);
  if (!exact) return { hit: false, reason: "none" };
  return { hit: true, reason: "short_line_exact", matchedKeyHash: exact.keyHash };
}

function recordShortLineIngress(shortKey) {
  if (!ENABLE_SHORT_LINE_DEDUP || !shortKey?.enabled) return;
  const now = Date.now();
  pruneShortLineIngressDedup(now);
  recentShortLineInbounds.push({
    keyHash: shortKey.keyHash,
    compact: shortKey.compact,
    time: now,
  });
}

function inferIngressOrigin(adapter, source) {
  const normalizedAdapter = `${adapter || "unknown"}`.trim().toLowerCase();
  const normalizedSource = `${source || "poll"}`.trim().toLowerCase();
  if (normalizedAdapter === "line") {
    return `line_${normalizedSource}`;
  }
  if (normalizedAdapter === "tproj") {
    return `tproj_${normalizedSource}`;
  }
  if (normalizedAdapter === "tmux") {
    return `tmux_${normalizedSource}`;
  }
  return `${normalizedAdapter}_${normalizedSource}`;
}

function parseOptionalMs(value) {
  const parsed = Number.parseInt(`${value ?? ""}`, 10);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function normalizeBurstLine(line) {
  return `${line || ""}`
    .normalize("NFKC")
    .replace(/\s+/g, " ")
    .trim();
}

function compactBurstLine(line) {
  return normalizeBurstLine(line)
    .toLowerCase()
    .replace(/[\p{P}\p{S}\s_]+/gu, "");
}

function burstLineEquivalent(a, b) {
  if (!a || !b) return false;
  const ca = compactBurstLine(a);
  const cb = compactBurstLine(b);
  if (!ca || !cb) return false;
  if (ca === cb) return true;
  const short = ca.length <= cb.length ? ca : cb;
  const long = ca.length <= cb.length ? cb : ca;
  if (short.length >= 6 && long.includes(short)) {
    const coverage = short.length / Math.max(long.length, 1);
    if (coverage >= 0.82) return true;
  }
  return compactSimilarityScore(ca, cb) >= 0.90;
}

function mergeLineBurstTexts(texts) {
  const candidates = (texts || [])
    .map((text) => `${text || ""}`.trim())
    .filter((text) => text.length > 0);
  if (candidates.length === 0) return "";
  if (candidates.length === 1) return candidates[0];

  const ordered = [...candidates].sort((a, b) => b.length - a.length);
  const mergedLines = [];
  const mergedCompacts = [];

  for (const text of ordered) {
    const lines = text
      .split("\n")
      .map((line) => normalizeBurstLine(line))
      .filter((line) => line.length > 0);
    for (const line of lines) {
      const compact = compactBurstLine(line);
      if (!compact) continue;
      const duplicate = mergedCompacts.some((existing, idx) => burstLineEquivalent(line, mergedLines[idx]) || existing === compact);
      if (duplicate) continue;
      mergedLines.push(line);
      mergedCompacts.push(compact);
      if (mergedLines.length >= LINE_BURST_MAX_SEGMENTS) break;
    }
    if (mergedLines.length >= LINE_BURST_MAX_SEGMENTS) break;
  }

  if (mergedLines.length === 0) return ordered[0];
  return mergedLines.join("\n");
}

function isStaleRepeatInbound(eventText, conversation, source) {
  const windowMs = activeStaleRepeatWindowMs();
  if (windowMs <= 0) return false;
  // Notification banner is explicit new-message signal; don't block it.
  if (source === "notification_banner") return false;

  const now = Date.now();
  while (recentStableInbounds.length > 0 && recentStableInbounds[0].time < now - windowMs) {
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
  // Owner's display name — treated as noise in AX tree parsing (configurable via filterDisplayName)
  if (_filterDisplayName && s.startsWith(_filterDisplayName) && (s.length === _filterDisplayName.length || /\W/.test(s[_filterDisplayName.length]))) return true;
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
/** @type {Map<string, { reason: string, setAt: number, questionText: string, options: string[], selectedIndex: number }>} */
const interactionPendingProjects = new Map();
const INTERACTION_PENDING_TTL_MS = 5 * 60 * 1000;

function normalizeQuestionRecord(questionLike = {}) {
  const questionText = `${questionLike.questionText || questionLike.question_text || ""}`.trim();
  const questionId = `${questionLike.questionId || questionLike.question_id || Date.now()}`;
  const selectedRaw = Number.parseInt(`${questionLike.selectedIndex ?? questionLike.question_selected ?? 0}`, 10);
  const selectedIndex = Number.isFinite(selectedRaw) ? Math.max(0, selectedRaw) : 0;
  const optionsRaw = Array.isArray(questionLike.options)
    ? questionLike.options
    : `${questionLike.question_options || ""}`.split("\n");
  const options = optionsRaw.map((x) => `${x}`.trim()).filter(Boolean);
  return { questionText, questionId, options, selectedIndex };
}

function pruneInteractionPending() {
  const now = Date.now();
  for (const [project, state] of interactionPendingProjects) {
    if (!state?.setAt || now - state.setAt > INTERACTION_PENDING_TTL_MS) {
      interactionPendingProjects.delete(project);
    }
  }
}

function setInteractionPending(project, reason, questionLike = {}) {
  if (!project) return;
  pruneInteractionPending();
  const normalized = normalizeQuestionRecord(questionLike);
  interactionPendingProjects.set(project, {
    reason: reason || "interaction_pending",
    setAt: Date.now(),
    questionText: normalized.questionText,
    options: normalized.options,
    selectedIndex: normalized.selectedIndex,
  });
}

function getInteractionPending(project) {
  if (!project) return null;
  pruneInteractionPending();
  return interactionPendingProjects.get(project) || null;
}

function clearInteractionPending(project) {
  if (!project) return false;
  return interactionPendingProjects.delete(project);
}

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
  // Strip any existing [CC/Codex ...] prefix (agent may have added one) before re-adding
  // to ensure consistent formatting.
  if (project) {
    result = result.replace(/^\[(CC|Codex) [^\]]*\]\n?/, "").trim();
    result = `[${sessionLabel(sessionType)} ${project}]\n${result}`;
  }

  return result;
}

function stripChoiceTags(text) {
  let result = `${text || ""}`.trim();
  if (!result) return "";
  result = result
    .replace(/<cc_task(?:\s+project="[^"]*")?>([\s\S]*?)<\/cc_task>/gi, "")
    .replace(/<cc_answer\s+project="[^"]*">([\s\S]*?)<\/cc_answer>/gi, "")
    .replace(/<cc_read\s+project="[^"]+"\s*\/?>(?:<\/cc_read>)?/gi, "")
    .trim();
  return result;
}

function hasChoiceTags(text) {
  return /<cc_task(?:\s+project="[^"]*")?>[\s\S]*?<\/cc_task>/i.test(text)
    || /<cc_answer\s+project="[^"]*">[\s\S]*?<\/cc_answer>/i.test(text);
}

function parseInteractivePromptFromText(text) {
  const rawLines = `${text || ""}`.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const lines = rawLines.map((l) => l.trim());
  const nonEmpty = lines.filter(Boolean);
  if (nonEmpty.length === 0) return null;

  /** @type {{ text: string, selected: boolean }[]} */
  const options = [];
  let selectedIndex = 0;

  for (const line of nonEmpty) {
    if (/^[❯●○]\s+/.test(line)) {
      const selected = /^[❯●]\s+/.test(line);
      const cleaned = line.replace(/^[❯●○]\s+/, "").trim();
      if (cleaned) {
        if (selected) selectedIndex = options.length;
        options.push({ text: cleaned, selected });
      }
      continue;
    }
    if (/^\d+\.\s+/.test(line)) {
      const cleaned = line.replace(/^\d+\.\s+/, "").trim();
      if (cleaned) options.push({ text: cleaned, selected: false });
    }
  }

  // Fallback: Codex interactive footer without clearly captured options.
  const hasShortcutFooter = /\?\s*for shortcuts/i.test(nonEmpty.join("\n"));

  if (options.length < 2 && !hasShortcutFooter) return null;

  let questionText = "";
  for (let i = nonEmpty.length - 1; i >= 0; i--) {
    const line = nonEmpty[i];
    if (/[?？]$/.test(line)) {
      questionText = line;
      break;
    }
  }
  if (!questionText) {
    questionText = hasShortcutFooter
      ? "Interactive prompt detected in terminal."
      : "A choice prompt is currently open in the session.";
  }

  return {
    questionText,
    options: options.map((x) => x.text),
    selectedIndex,
    reason: hasShortcutFooter ? "shortcuts_footer" : "option_markers",
  };
}

function detectInteractionPendingFromCompletion({ payload, text, project }) {
  const waitingReason = `${payload?.waiting_reason || payload?.waitingReason || ""}`.toLowerCase();
  const pending = pendingQuestions.get(project);
  const parsed = parseInteractivePromptFromText(text);
  const hasShortcutFooter = /\?\s*for shortcuts/i.test(`${text || ""}`);

  const hintByReason = waitingReason === "permission_prompt" || waitingReason === "askuserquestion";
  const normalizedPending = pending ? normalizeQuestionRecord(pending) : null;
  const normalizedParsed = parsed ? normalizeQuestionRecord(parsed) : null;
  const parsedHasOptions = (normalizedParsed?.options?.length || 0) >= 2;
  const pendingHasOptions = (normalizedPending?.options?.length || 0) >= 2;

  if (!ENABLE_INTERACTION_PENDING_STRICT_V2) {
    if (!parsed && !hintByReason && !pending && !hasShortcutFooter) return null;
  } else {
    // Strict mode: shortcuts footer alone is not enough.
    const hasStructuredEvidence = hintByReason || parsedHasOptions || pendingHasOptions;
    if (!hasStructuredEvidence) return null;
  }

  let reason = "pending_question";
  if (hintByReason) {
    reason = waitingReason;
  } else if (parsedHasOptions && parsed?.reason) {
    reason = parsed.reason;
  } else if (pendingHasOptions) {
    reason = "pending_question";
  } else if (!ENABLE_INTERACTION_PENDING_STRICT_V2 && hasShortcutFooter) {
    reason = "shortcuts_footer";
  }

  return {
    reason,
    questionText: normalizedParsed?.questionText || normalizedPending?.questionText || "Interactive prompt detected in terminal.",
    options: parsedHasOptions
      ? normalizedParsed.options
      : (pendingHasOptions ? normalizedPending.options : []),
    selectedIndex: Number.isFinite(normalizedParsed?.selectedIndex)
      ? normalizedParsed.selectedIndex
      : (normalizedPending?.selectedIndex || 0),
    questionId: normalizedPending?.questionId || `${Date.now()}`,
  };
}

function buildPairingGuidance({ project = "", mode = "", eventKind = "", sessionType = "claude_code", firstTime = false } = {}) {
  const proj = project || "current";
  const m = mode || "observe";
  const k = eventKind || "update";
  const label = sessionLabel(sessionType);
  const sessionTypeName = sessionType === "codex" ? "Codex" : "Claude Code";
  const vars = { label, project: proj, mode: m, sessionTypeName };
  const parts = [];

  if (firstTime) {
    parts.push(...fillTemplateLines(_prompts.firstTime, vars));
  }

  // Per-event guidance
  if (k === "completion") {
    parts.push(fillTemplate(_prompts.completion.header, vars));
    const modeLines = _prompts.completion[m];
    if (modeLines) {
      parts.push(...(Array.isArray(modeLines) ? fillTemplateLines(modeLines, vars) : [fillTemplate(modeLines, vars)]));
    }
    parts.push(_prompts.completion.noReply);
  } else if (k === "question") {
    const modeLines = _prompts.question[m];
    if (modeLines) {
      parts.push(...(Array.isArray(modeLines) ? fillTemplateLines(modeLines, vars) : [fillTemplate(modeLines, vars)]));
    }
    parts.push(_prompts.question.noReply);
  }

  return parts.join("\n");
}

// ── Task failure message enrichment ───────────────────────────

/**
 * Build an enriched task failure message that includes progress context.
 * Includes: error message, progress trail (last 20 lines), last snapshot (last 10 lines), and line text.
 * @param {string} errorMsg — the error description
 * @param {string} lineText — AI reply text minus the <cc_task> tag
 * @param {string} project — target project name
 * @returns {string}
 */
function buildTaskFailureMessage(errorMsg, lineText, project) {
  const parts = [`[Task send failed: ${errorMsg}]`];

  if (ENABLE_DEBUG_TASK_FAILURE_CONTEXT) {
    const MAX_TRAIL_LINES = 20;
    const MAX_SNAPSHOT_LINES = 10;
    const trail = getProgressTrail(project);
    if (trail) {
      const lines = trail.split("\n");
      const tail = lines.length > MAX_TRAIL_LINES
        ? lines.slice(-MAX_TRAIL_LINES).join("\n")
        : trail;
      parts.push(`[Progress Trail (last ${Math.min(lines.length, MAX_TRAIL_LINES)} lines)]\n${tail}`);
    }

    const snapshot = getProgressSnapshot(project);
    if (snapshot?.text) {
      const sLines = snapshot.text.split("\n");
      const sTail = sLines.length > MAX_SNAPSHOT_LINES
        ? sLines.slice(-MAX_SNAPSHOT_LINES).join("\n")
        : snapshot.text;
      parts.push(`[Last Snapshot]\n${sTail}`);
    }
  }

  if (lineText) parts.push(lineText);
  return parts.join("\n\n");
}

function stripAnsiControlCodes(text) {
  return `${text || ""}`
    .replace(/\u001B\[[0-9;]*[a-zA-Z]/g, "")
    .replace(/\u001B\][^\u0007]*\u0007/g, "");
}

function isTmuxFooterLine(line) {
  const s = `${line || ""}`.trim();
  if (!s) return false;
  if (/\?\s+for shortcuts/i.test(s)) return true;
  if (/^\d+%\s+context left$/i.test(s)) return true;
  if (/^\d+%\s+context window$/i.test(s)) return true;
  if (/\d+%\s+context left/i.test(s)) return true;
  if (/\d+%\s+context window/i.test(s)) return true;
  if (/^autonomous:\s+/i.test(s)) return true;
  return false;
}

function isTmuxDividerLine(line) {
  const s = `${line || ""}`.trim();
  return /^[-─━]{3,}$/.test(s);
}

function detectTmuxInputDraft(lines) {
  const source = Array.isArray(lines)
    ? lines.map((line) => stripAnsiControlCodes(line))
    : [];
  if (source.length === 0) {
    return { parseOk: false, reason: "empty_capture", isTyping: true, draftText: "" };
  }

  const tail = source.slice(-TMUX_TYPING_GUARD_SCAN_TAIL_LINES);
  let end = tail.length - 1;
  while (end >= 0 && !tail[end].trim()) end--;
  if (end < 0) {
    return { parseOk: false, reason: "blank_capture", isTyping: true, draftText: "" };
  }

  while (end >= 0 && (isTmuxFooterLine(tail[end]) || isTmuxDividerLine(tail[end]))) end--;
  if (end < 0) {
    return { parseOk: false, reason: "footer_only_capture", isTyping: true, draftText: "" };
  }

  const searchStart = Math.max(0, end - 16);
  let promptIndex = -1;
  for (let i = end; i >= searchStart; i--) {
    if (TMUX_PROMPT_LINE_RE.test(tail[i])) {
      promptIndex = i;
      break;
    }
  }

  if (promptIndex < 0) {
    return { parseOk: false, reason: "prompt_not_found", isTyping: true, draftText: "" };
  }

  if (end - promptIndex > TMUX_TYPING_GUARD_MAX_PROMPT_DISTANCE_LINES) {
    return { parseOk: false, reason: "prompt_too_far_from_bottom", isTyping: true, draftText: "" };
  }

  const draftParts = [];
  const firstDraft = tail[promptIndex]
    .replace(TMUX_PROMPT_LINE_RE, "")
    .replace(/[▌█▋▍▎▏]+$/u, "")
    .trim();
  if (firstDraft) draftParts.push(firstDraft);

  const continuationEnd = Math.min(end, promptIndex + TMUX_TYPING_GUARD_MAX_CONTINUATION_LINES);
  for (let i = promptIndex + 1; i <= continuationEnd; i++) {
    const raw = tail[i];
    const trimmed = raw.trim();
    if (!trimmed) continue;
    if (isTmuxFooterLine(raw) || isTmuxDividerLine(raw) || TMUX_PROMPT_LINE_RE.test(raw)) break;
    draftParts.push(trimmed.replace(/[▌█▋▍▎▏]+$/u, ""));
  }

  const draftText = draftParts.join(" ").replace(/\s+/g, " ").trim();
  if (!draftText) {
    return { parseOk: true, reason: "prompt_idle", isTyping: false, draftText: "" };
  }
  if (isTemplatePromptDraft(draftText)) {
    return { parseOk: true, reason: "template_prompt_idle", isTyping: false, draftText: "" };
  }
  return { parseOk: true, reason: "draft_detected", isTyping: true, draftText };
}

function isTemplatePromptDraft(text) {
  const s = `${text || ""}`.trim().toLowerCase();
  if (!s) return false;
  if (s === "implement {feature}") return true;
  if (s === "run /review on my current changes") return true;
  return false;
}

async function inspectTmuxDraftBeforeTaskSend({ apiUrl, project, traceId, log }) {
  try {
    const result = await clawgateTmuxRead(apiUrl, project, TMUX_TYPING_GUARD_READ_LINES, traceId);
    if (!result?.ok) {
      const errCode = `${result?.error?.code || ""}`.toLowerCase();
      const reason = result?.error?.message || result?.error?.code || "pane_read_failed";
      if (errCode === "session_not_found" || errCode === "tmux_target_missing") {
        log?.debug?.(`clawgate: typing guard bypass for "${project}" (${errCode})`);
        return {
          blocked: false,
          reason: "non_authoritative_host",
          message: "",
        };
      }
      log?.warn?.(`clawgate: typing guard read failed for "${project}": ${reason}`);
      return {
        blocked: true,
        reason: "pane_read_failed",
        message: `Session '${project}' prompt state is unknown (read failed: ${reason}). Skipped task send to avoid overwriting user input.`,
      };
    }

    const lines = Array.isArray(result?.result?.messages)
      ? result.result.messages.map((item) => `${item?.text || ""}`)
      : [];
    const detection = detectTmuxInputDraft(lines);
    if (!detection.parseOk) {
      log?.warn?.(`clawgate: typing guard parse failed for "${project}" (${detection.reason})`);
      return {
        blocked: true,
        reason: detection.reason,
        message: `Session '${project}' prompt state is unknown (${detection.reason}). Skipped task send to avoid overwriting user input.`,
      };
    }
    if (detection.isTyping) {
      const snippet = detection.draftText.slice(0, 80);
      log?.info?.(`clawgate: typing guard blocked task send for "${project}" (draft="${snippet}")`);
      return {
        blocked: true,
        reason: "draft_detected",
        message: `Session '${project}' has unsent input in terminal. Skipped task send to avoid overwriting user input.`,
      };
    }
    return { blocked: false, reason: "idle_prompt", message: "" };
  } catch (err) {
    const reason = err?.message || String(err);
    log?.warn?.(`clawgate: typing guard exception for "${project}": ${reason}`);
    return {
      blocked: true,
      reason: "pane_read_exception",
      message: `Session '${project}' prompt state is unknown (read exception). Skipped task send to avoid overwriting user input.`,
    };
  }
}

// ── Autonomous task chaining ──────────────────────────────────

/**
 * Extract <cc_task> from AI reply and send to Claude Code via tmux.
 * Returns null if no task tag found.
 * @param {object} params
 * @param {string} params.replyText — full AI reply text
 * @param {string} params.project — source tmux project (defaults target unless tag overrides)
 * @param {string} params.apiUrl
 * @param {object} [params.log]
 * @returns {Promise<{lineText: string, taskText: string} | {error: Error, lineText: string} | null>}
 */
async function tryExtractAndSendTask({
  replyText, project, apiUrl, traceId, log, mode,
  resolveMode = (targetProject) => sessionModes.get(targetProject) || "ignore",
}) {
  const taskMatch = replyText.match(/<cc_task(?:\s+project="([^"]+)")?>([\s\S]*?)<\/cc_task>/i);
  if (!taskMatch) return null;

  const explicitTarget = `${taskMatch[1] || ""}`.trim();
  const taskText = `${taskMatch[2] || ""}`.trim();
  if (!taskText) return null;

  const lineText = replyText
    .replace(/<cc_task(?:\s+project="[^"]*")?>([\s\S]*?)<\/cc_task>/i, "")
    .trim();

  const sourceProject = `${project || ""}`.trim();
  const targetProject = explicitTarget || sourceProject;
  if (!targetProject) {
    const err = new Error("target project is missing (use <cc_task project=\"...\">)");
    return { error: err, errorCode: "target_project_missing", lineText, taskText, targetProject: "" };
  }

  const targetMode = `${resolveMode(targetProject) || "ignore"}`.toLowerCase();
  if (targetMode !== "autonomous" && targetMode !== "auto") {
    const err = new Error(`Session '${targetProject}' is in ${targetMode} mode (task send disabled)`);
    return { error: err, errorCode: "session_read_only", lineText, taskText, targetProject };
  }

  const interactionPending = getInteractionPending(targetProject);
  if (interactionPending) {
    const err = new Error(`Session '${targetProject}' is waiting for user interaction (${interactionPending.reason})`);
    return { error: err, errorCode: "interaction_pending", lineText, taskText, targetProject };
  }

  // LGTM termination: intercept before sending to CC — don't pollute the session with "LGTM" tasks
  const LOOP_TERMINATE = /^(lgtm|done|approved|no issues|looks good(?: to me)?|ship it)[!?.]*$/i;
  if (LOOP_TERMINATE.test(taskText)) {
    return { lineText, taskText, targetProject, terminated: true };
  }

  // Prefix task with canonical wrapped form so CC/Codex can treat it as OpenClaw-origin
  // while preserving sender metadata compatibility: [from:OpenClaw Agent - {Mode}]
  const sourceMode = `${mode || ""}`.trim() || targetMode;
  const modeLabel = sourceMode ? sourceMode.charAt(0).toUpperCase() + sourceMode.slice(1) : "Unknown";
  const prefixedTask = `[from:OpenClaw Agent - ${modeLabel}] ${taskText}`;

  // 2 tries total (initial + one retry), 6s total window.
  const MAX_RETRIES = 1;
  const RETRY_DELAY_MS = 3000;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const typingGuard = await inspectTmuxDraftBeforeTaskSend({
      apiUrl,
      project: targetProject,
      traceId,
      log,
    });
    if (typingGuard.blocked) {
      if (typingGuard.reason === "draft_detected") {
        const queueResult = enqueuePendingTask({
          project: sourceProject || targetProject,
          targetProject,
          taskText,
          prefixedTask,
          mode: sourceMode,
          traceId,
          log,
        });
        return {
          error: new Error(typingGuard.message),
          errorCode: "session_typing_busy",
          lineText,
          taskText,
          targetProject,
          queued: queueResult.queued,
          queuedDedup: queueResult.dedup,
        };
      }
      log?.warn?.(
        `clawgate: typing guard bypass for "${targetProject}" reason=${typingGuard.reason} (will attempt send)`
      );
    }

    try {
      const result = await clawgateTmuxSend(apiUrl, targetProject, prefixedTask, traceId);
      if (result?.ok) {
        const queuedKey = buildPendingTaskKey(targetProject, taskText);
        pendingTaskQueue.delete(queuedKey);
        log?.info?.(`clawgate: task sent to CC (${targetProject}): "${taskText.slice(0, 80)}"`);
        clearTaskSendFailureStreak(targetProject);
        setTaskGoal(targetProject, taskText);
        if (clearReviewDone(targetProject)) {
          log?.info?.(`clawgate: review-done CLEARED for "${targetProject}" — new task sent, completions resumed`);
        }
        return { lineText, taskText, targetProject };
      }

      // Retry on transient errors (session_busy = CC running, session_not_found = federation reconnecting)
      const err = result?.error;
      const retriableCodes = ["session_busy", "session_not_found"];
      if (err?.retriable && retriableCodes.includes(err?.code) && attempt < MAX_RETRIES) {
        log?.info?.(`clawgate: CC unavailable [${err.code}] (${err.message || err.details || ""}), retry ${attempt + 1}/${MAX_RETRIES} in ${RETRY_DELAY_MS / 1000}s`);
        await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
        continue;
      }

      const errCode = err?.code || "unknown_error";
      const errMsg = err?.message || err?.code || "unknown error";
      if (errCode === "session_busy") {
        const queueResult = enqueuePendingTask({
          project: sourceProject || targetProject,
          targetProject,
          taskText,
          prefixedTask,
          mode: sourceMode,
          traceId,
          log,
        });
        return {
          error: new Error(errMsg),
          errorCode: errCode,
          lineText,
          taskText,
          targetProject,
          queued: queueResult.queued,
          queuedDedup: queueResult.dedup,
        };
      }
      log?.error?.(`clawgate: failed to send task to CC (${targetProject}): ${errMsg} — task: ${taskText.slice(0, 200)}`);
      // Don't pollute LINE with internal routing errors — send clean review text only
      return { error: new Error(errMsg), errorCode: errCode, lineText, taskText, targetProject };
    } catch (err) {
      const errCode = err?.name || "send_exception";
      const errMessage = `${err?.message || err || ""}`.toLowerCase();
      if (errMessage.includes("currently running") || errMessage.includes("session busy")) {
        const queueResult = enqueuePendingTask({
          project: sourceProject || targetProject,
          targetProject,
          taskText,
          prefixedTask,
          mode: sourceMode,
          traceId,
          log,
        });
        return {
          error: err instanceof Error ? err : new Error(String(err)),
          errorCode: "session_busy",
          lineText,
          taskText,
          targetProject,
          queued: queueResult.queued,
          queuedDedup: queueResult.dedup,
        };
      }
      log?.error?.(`clawgate: failed to send task to CC (${targetProject}): ${err} — task: ${taskText.slice(0, 200)}`);
      return { error: err, errorCode: errCode, lineText, taskText, targetProject };
    }
  }

  // Exhausted retries — CC stayed unavailable for the entire retry window
  log?.error?.(`clawgate: exhausted ${MAX_RETRIES + 1} tries sending task to CC (${targetProject}) — task: ${taskText.slice(0, 200)}`);
  return {
    error: new Error("max retries exceeded"),
    errorCode: "max_retries_exceeded",
    lineText,
    taskText,
    targetProject,
  };
}

/**
 * Extract <cc_read project="..."/> from AI reply and read tmux pane content.
 * Returns null if no read tag found.
 * Self-closing or body form: <cc_read project="game01"/> or <cc_read project="game01"></cc_read>
 * @param {object} params
 * @param {string} params.replyText — full AI reply text
 * @param {string} params.apiUrl
 * @param {string} [params.traceId]
 * @param {object} [params.log]
 * @returns {Promise<{lineText: string, paneContent: string, project: string} | {error: Error, lineText: string} | null>}
 */
async function tryExtractAndReadPane({ replyText, apiUrl, traceId, log }) {
  const readMatch = replyText.match(/<cc_read\s+project="([^"]+)"\s*\/?>(?:<\/cc_read>)?/i);
  if (!readMatch) return null;

  const project = readMatch[1].trim();
  const lineText = replyText
    .replace(/<cc_read\s+project="[^"]+"\s*\/?>(?:<\/cc_read>)?/i, "")
    .trim();

  if (!project) {
    return { error: new Error("project name is missing in <cc_read>"), lineText };
  }

  try {
    const result = await clawgateTmuxRead(apiUrl, project, 80, traceId);
    if (!result?.ok) {
      const errMsg = result?.error?.message || "failed to read pane";
      log?.error?.(`clawgate: cc_read failed for "${project}": ${errMsg}`);
      return { error: new Error(errMsg), lineText, project };
    }

    const messages = result.result?.messages || [];
    const paneContent = messages.map((m) => m.text).join("\n");
    log?.info?.(`clawgate: cc_read OK for "${project}" (${messages.length} lines)`);
    return { lineText, paneContent, project };
  } catch (err) {
    log?.error?.(`clawgate: cc_read exception for "${project}": ${err}`);
    return { error: err, lineText, project };
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
      clearInteractionPending(project);
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
  const taskHint = hasTaskCapable ? _prompts.rosterFooter.taskHint : "";

  // Check for pending questions
  const hasQuestions = pendingQuestions.size > 0;
  const answerHint = hasQuestions ? _prompts.rosterFooter.answerHint : "";

  // Read hint is always available when sessions exist
  const readHint = _prompts.rosterFooter.readHint || "";

  const sessionCount = sessionModes.size;
  return `[Active Claude Code Projects: ${sessionCount} session${sessionCount !== 1 ? "s" : ""}]\n${roster}${taskHint}${answerHint}${readHint}`;
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

  const conversationKey = defaultConversation || conversation;
  const activeProject = getActiveProject(conversationKey);
  const sourceTaskProject = `${activeProject?.project || ""}`.trim();
  const sourceTaskMode = sourceTaskProject ? (sessionModes.get(sourceTaskProject) || "ignore") : "ignore";
  const suppressAutonomousRoutingNoise = ENABLE_AUTONOMOUS_LOOP_GUARD_V2 && sourceTaskMode === "autonomous";

  // Clear active project so outbound.sendText doesn't leak tmux prefixes into messenger replies.
  clearActiveProject(conversationKey);

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

    // Try to extract <cc_read> — on-demand pane reading for the reviewer agent
    const readResult = await tryExtractAndReadPane({ replyText: text, apiUrl, traceId, log });
    if (readResult) {
      if (readResult.error) {
        const msg = `[Pane read failed: ${readResult.error.message || readResult.error}]${readResult.lineText ? "\n\n" + readResult.lineText : ""}`;
        try { await clawgateSend(apiUrl, conversation, msg, traceId); recordPluginSend(msg); } catch {}
      } else {
        const header = `[Pane: ${readResult.project}]`;
        const content = readResult.paneContent || "(empty)";
        const msg = readResult.lineText
          ? `${readResult.lineText}\n\n${header}\n${content}`
          : `${header}\n${content}`;
        try { await clawgateSend(apiUrl, conversation, msg, traceId); recordPluginSend(msg); } catch {}
      }
      return;
    }

    // Try to extract <cc_task> from AI reply.
    // Default target is sourceTaskProject, but explicit cross-session
    // route is allowed via <cc_task project="target-project">.
    const result = await tryExtractAndSendTask({
      replyText: text,
      project: sourceTaskProject,
      apiUrl,
      traceId,
      log,
      mode: sourceTaskMode,
      resolveMode: (targetProject) => sessionModes.get(targetProject) || "ignore",
    });
    if (result) {
      // LGTM termination from inbound — forward lineText to LINE, set review-done
      if (result.terminated) {
        const proj = result.targetProject || sourceTaskProject || "unknown";
        clearTaskSendFailureStreak(proj);
        setReviewDone(proj, "lgtm_inbound");
        log?.info?.(`clawgate: [${accountId}] review-done SET for "${proj}" — LGTM via inbound`);
        if (result.lineText) {
          try { await clawgateSend(apiUrl, conversation, result.lineText, traceId); recordPluginSend(result.lineText); } catch {}
        }
        return;
      }
      if (result.error) {
        const targetProject = result.targetProject || sourceTaskProject || "unknown";
        const errorCode = result.errorCode || "unknown_error";
        const errorMessage = result.error.message || String(result.error);
        const category = classifyTaskSendFailure({ errorCode, errorMessage });
        const eventName = `task_send_failed.${category}`;

        traceLog(log, "warn", {
          trace_id: traceId,
          stage: eventName,
          action: "cc_task_send",
          status: "failed",
          project: targetProject,
          error_code: errorCode,
        });

        if (suppressAutonomousRoutingNoise) {
          const streak = trackTaskSendFailureStreak({ project: targetProject, category });
          logAutonomousLineEvent(log, {
            accountId,
            project: targetProject,
            reason: "routing_error",
            status: "suppressed",
            detail: `inbound_autonomous_guard category=${category} count=${streak.count}`,
          });
          return;
        }

        if (category !== "other") {
          const streak = trackTaskSendFailureStreak({ project: targetProject, category });
          log?.info?.(
            `clawgate: [${accountId}] task send benign failure suppressed (project=${targetProject}, category=${category}, count=${streak.count})`
          );
          if (category === "typing_busy") {
            if (result.queued) {
              log?.info?.(
                `clawgate: [${accountId}] typing-busy task queued (project=${targetProject}, dedup=${result.queuedDedup ? 1 : 0})`
              );
            } else {
              const shouldNotifyTyping = shouldNotifyTaskSendError({
                project: targetProject,
                errorCode,
                taskText: "",
              });
              if (shouldNotifyTyping) {
                const advisory = buildTypingBusyAdvisoryLine(targetProject);
                try {
                  await clawgateSend(apiUrl, conversation, advisory, traceId);
                  recordPluginSend(advisory);
                } catch (err) {
                  log?.error?.(`clawgate: [${accountId}] send typing-busy advisory to LINE failed: ${err}`);
                }
              } else {
                log?.info?.(`clawgate: [${accountId}] typing-busy advisory suppressed (project=${targetProject})`);
              }
            }
          } else if (result.lineText) {
            const shouldForwardLine = shouldNotifyTaskSendError({
              project: targetProject,
              errorCode,
              taskText: result.taskText || "",
            });
            if (shouldForwardLine) {
              try {
                await clawgateSend(apiUrl, conversation, result.lineText, traceId);
                recordPluginSend(result.lineText);
              } catch (err) {
                log?.error?.(`clawgate: [${accountId}] send fallback review text to LINE failed: ${err}`);
              }
            } else {
              log?.info?.(`clawgate: [${accountId}] benign failure fallback line suppressed (project=${targetProject}, code=${errorCode})`);
            }
          }
          if (streak.shouldEscalate && category !== "typing_busy") {
            const msg = buildTaskFailureEscalationLine({
              project: targetProject,
              category,
              streakDurationMs: streak.streakDurationMs,
            });
            try {
              await clawgateSend(apiUrl, conversation, msg, traceId);
              recordPluginSend(msg);
              traceLog(log, "info", {
                trace_id: traceId,
                stage: "task_send_escalated",
                action: "line_send",
                status: "ok",
                project: targetProject,
                error_code: errorCode,
                escalation_sec: Math.round(streak.streakDurationMs / 1000),
              });
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] send task escalation to LINE failed: ${err}`);
            }
          }
        } else {
          clearTaskSendFailureStreak(targetProject);
          const shouldNotify = shouldNotifyTaskSendError({
            project: targetProject,
            errorCode,
            taskText: result.taskText || "",
          });
          if (shouldNotify) {
            const msg = buildTaskFailureMessage(errorMessage, result.lineText, targetProject);
            try {
              await clawgateSend(apiUrl, conversation, msg, traceId);
              recordPluginSend(msg);
            } catch (err) {
              log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
            }
          } else {
            log?.info?.(`clawgate: [${accountId}] task send error notice suppressed (project=${targetProject}, code=${errorCode})`);
          }
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
  if (mode !== "autonomous") setAutonomousLoopActive(project, false);
  // Question event means CC is actively working — clear review-done suppression
  if (clearReviewDone(project)) {
    log?.info?.(`clawgate: [${accountId}] review-done CLEARED for "${project}" — question event received`);
  }

  // Reset autonomous conversation round counter (question = CC responded, not agent's turn)
  questionRoundMap.delete(project);

  // Track pending question
  const options = optionsRaw.split("\n").filter(Boolean);
  pendingQuestions.set(project, { questionText, questionId, options, selectedIndex, setAt: Date.now() });
  setInteractionPending(project, "question_event", { questionText, questionId, options, selectedIndex });

  const resolvedProjectPath = tmuxTarget ? (resolveProjectPath(project, tmuxTarget) || "") : "";

  // Invalidate context cache (files may have changed while CC was working)
  invalidateProject(project);

  // --- Context layers (parallel to handleTmuxCompletion) ---
  const stable = getStableContext(project, tmuxTarget);
  const dynamic = getDynamicEnvelope(project, tmuxTarget);

  const optionalParts = [];

  // Stable project context
  if (stable && stable.isNew && stable.context) {
    optionalParts.push(`[Project Context (hash: ${stable.hash})]\n${stable.context}`);
    if (_ccKnowledge) {
      optionalParts.push(_ccKnowledge);
    }
  } else if (stable && stable.hash) {
    optionalParts.push(
      `[Project Context unchanged (hash: ${stable.hash}) - see earlier in conversation]`
    );
  }

  const projectView = getProjectViewReader(accountId, log).getContextBlock({
    project,
    mode,
    resolvedProjectPath,
    hasStableContext: !!stable?.context,
  });
  if (projectView) {
    optionalParts.push(projectView);
  }

  // Task goal (what the reviewer agent asked CC to do — helps the agent understand what the question is about)
  // Note: DON'T clearTaskGoal here — question doesn't end the task
  const taskGoal = getTaskGoal(project);
  if (taskGoal) {
    optionalParts.push(`[Task Goal]\n${taskGoal}`);
  }

  // Dynamic envelope (git state)
  if (dynamic && dynamic.envelope) {
    optionalParts.push(`[Current State]\n${dynamic.envelope}`);
  }

  // Pane context (output above the question — may contain plan content)
  // Filter noise and cap before trail so we can dedup trail against it
  const MAX_QUESTION_CONTEXT_CHARS = 3000;
  let questionContext = filterPaneNoise(payload.question_context || "");
  if (questionContext) {
    questionContext = capText(questionContext, MAX_QUESTION_CONTEXT_CHARS, "tail");
    optionalParts.push(`[Screen Context (above question)]\n${questionContext}`);
  }

  // Progress trail (what CC did so far — helps the agent understand the question in context)
  // Note: DON'T clearProgressTrail — question doesn't end the task
  // Deduplicate against questionContext to avoid repeating the same content
  const trail = getProgressTrail(project);
  if (trail && questionContext) {
    const deduped = deduplicateTrailAgainst(trail, questionContext);
    if (deduped) optionalParts.push(`[Execution Progress Trail]\n${deduped}`);
  } else if (trail) {
    optionalParts.push(`[Execution Progress Trail]\n${trail}`);
  }

  // Pairing guidance
  const isFirstGuidance = !guidanceSentProjects.has(project);
  const guidance = buildPairingGuidance({ project, mode, eventKind: "question", sessionType, firstTime: isFirstGuidance });
  if (isFirstGuidance) guidanceSentProjects.add(project);

  // Format numbered options for the reviewer agent
  const numberedOptions = options.map((opt, i) => {
    const marker = i === selectedIndex ? ">>>" : "   ";
    return `${marker} ${i + 1}. ${opt}`;
  }).join("\n");

  // Question body
  const qbTemplate = mode === "auto" ? _prompts.questionBody.auto : _prompts.questionBody.default;
  const questionBody = fillTemplate(qbTemplate, { label, project, questionText, numberedOptions });
  const requiredParts = [guidance, questionBody];

  // Apply total message cap with guidance preservation (trim optional context first)
  const MAX_TOTAL_BODY_CHARS = 16000;
  const body = buildPrioritizedBody({
    requiredParts,
    optionalParts,
    maxChars: MAX_TOTAL_BODY_CHARS,
    log,
    scope: "tmux-question",
  });

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

  log?.info?.(`clawgate: [${accountId}] tmux question from "${project}": "${questionText.slice(0, 80)}" (${options.length} options, prompt=${_promptMeta.hash})`);

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

    // Default: forward to LINE (observe + auto fallback).
    // Autonomous question events are user-decision checkpoints:
    // recommendation to LINE is allowed, but task/answer tags must not execute.
    if (mode === "autonomous") {
      const hadChoiceTags = hasChoiceTags(replyText);
      const advisoryRaw = stripChoiceTags(replyText);
      if (hadChoiceTags) {
        traceLog(log, "warn", {
          trace_id: traceId,
          stage: "interaction_pending_blocked",
          action: "question_advisory",
          status: "ok",
          project,
          detail: "choice_tags_stripped",
        });
      }
      const advisory = normalizeLineReplyText(
        advisoryRaw || "Interactive prompt is waiting. Please choose an option in the terminal.",
        { project, sessionType, eventKind: "question" }
      );
      const shouldNotify = shouldNotifyInteractionPending({
        project,
        reason: "question_advisory",
        questionText,
        options,
      });
      if (!shouldNotify) {
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "interaction_pending",
          status: "suppressed",
          detail: "question_advisory_dedup",
        });
        return;
      }
      try {
        await sendLine(defaultConversation || project, advisory);
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "interaction_pending",
          status: "sent",
          detail: "question_advisory",
        });
      } catch (err) {
        log?.error?.(`clawgate: [${accountId}] send autonomous question advisory failed: ${err}`);
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "interaction_pending",
          status: "failed",
          detail: String(err),
        });
      }
      return;
    }

    // Observe + auto fallback
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

  // Guard: review-done — LGTM closed the review loop, suppress completions until next task
  const reviewDoneState = getReviewDone(project);
  if (reviewDoneState) {
    log?.debug?.(`clawgate: [${accountId}] skipping completion for "${project}" — review-done(reason=${reviewDoneState.reason}, awaiting next task)`);
    // Still update session state so roster stays accurate
    sessionModes.set(project, mode);
    sessionStatuses.set(project, "waiting_input");
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

  if (shouldSkipCompletionDispatch({ project, mode, sessionType, text })) {
    sessionModes.set(project, mode);
    sessionStatuses.set(project, "waiting_input");
    log?.info?.(`clawgate: [${accountId}] completion_dedup_skipped project=${project} mode=${mode}`);
    return;
  }

  // Track session state for roster
  sessionModes.set(project, mode);
  sessionStatuses.set(project, "waiting_input");
  if (mode !== "autonomous") setAutonomousLoopActive(project, false);

  const interactionPending = mode === "autonomous"
    ? detectInteractionPendingFromCompletion({ payload, text, project })
    : null;
  if (interactionPending) {
    pendingQuestions.set(project, {
      questionText: interactionPending.questionText,
      questionId: interactionPending.questionId || String(Date.now()),
      options: interactionPending.options || [],
      selectedIndex: interactionPending.selectedIndex || 0,
      setAt: Date.now(),
    });
    setInteractionPending(project, interactionPending.reason, interactionPending);
    traceLog(log, "warn", {
      trace_id: traceId,
      stage: "interaction_pending_detected",
      action: "tmux_completion",
      status: "ok",
      project,
      detail: interactionPending.reason,
    });
  } else {
    // Clear any pending question only when we are not in an interaction-pending state.
    pendingQuestions.delete(project);
    clearInteractionPending(project);
  }

  // Keep last output in progress snapshot for roster visibility (waiting_input shows last output)
  setProgressSnapshot(project, text);

  // Resolve project path and register for roster
  const resolvedProjectPath = tmuxTarget ? (resolveProjectPath(project, tmuxTarget) || "") : "";

  // Invalidate context cache (files may have changed during the task)
  invalidateProject(project);

  // Build two-layer context (stable + dynamic)
  const stable = getStableContext(project, tmuxTarget);
  const dynamic = getDynamicEnvelope(project, tmuxTarget);

  const optionalParts = [];

  if (stable && stable.isNew && stable.context) {
    optionalParts.push(`[Project Context (hash: ${stable.hash})]\n${stable.context}`);
    if (_ccKnowledge) {
      optionalParts.push(_ccKnowledge);
    }
  } else if (stable && stable.hash) {
    optionalParts.push(
      `[Project Context unchanged (hash: ${stable.hash}) - see earlier in conversation]`
    );
  }

  const projectView = getProjectViewReader(accountId, log).getContextBlock({
    project,
    mode,
    resolvedProjectPath,
    hasStableContext: !!stable?.context,
  });
  if (projectView) {
    optionalParts.push(projectView);
  }

  // Task goal (what the reviewer agent asked CC to do — enables goal vs result comparison)
  const taskGoal = getTaskGoal(project);
  if (taskGoal) {
    optionalParts.push(`[Task Goal]\n${taskGoal}`);
  }
  clearTaskGoal(project);

  if (dynamic && dynamic.envelope) {
    optionalParts.push(`[Current State]\n${dynamic.envelope}`);
  }

  // Filter noise from completion text (CC UI chrome: bars, spinners, etc.)
  const cleanedText = filterPaneNoise(text);
  const displayText = cleanedText || text; // fallback if everything was noise

  // Include accumulated progress trail (what CC did between progress events)
  // Deduplicate against completion text to avoid repeating the same content
  const trail = getProgressTrail(project);
  if (trail) {
    const deduped = deduplicateTrailAgainst(trail, displayText);
    if (deduped) optionalParts.push(`[Execution Progress Trail]\n${deduped}`);
  }
  clearProgressTrail(project);

  const isFirstGuidance = !guidanceSentProjects.has(project) && !interactionPending;
  const guidance = buildPairingGuidance({
    project,
    mode,
    eventKind: interactionPending ? "question" : "completion",
    sessionType,
    firstTime: isFirstGuidance,
  });
  if (isFirstGuidance) guidanceSentProjects.add(project);

  let requiredParts;
  if (interactionPending) {
    const options = (interactionPending.options || [])
      .map((opt, i) => `${i === interactionPending.selectedIndex ? ">>>" : "   "} ${i + 1}. ${opt}`)
      .join("\n");
    const interactionBody = options
      ? fillTemplate(_prompts.questionBody.default, {
          label: sessionLabel(sessionType),
          project,
          questionText: interactionPending.questionText,
          numberedOptions: options,
        })
      : `[${sessionLabel(sessionType)} ${project}] Interactive prompt is open in terminal.\n\n${interactionPending.questionText}\n\n[Give recommendation only. Do NOT use <cc_task> or <cc_answer>.]`;
    requiredParts = [guidance, interactionBody];
  } else {
    // Append metadata notes so the reviewer agent understands information gaps
    const hasGoal = !!taskGoal;
    const hasUncommitted = dynamic?.envelope?.includes("Uncommitted changes:");
    const hasTrail = !!trail;
    const metaNotes = [
      !hasGoal ? "(No task goal registered — user-initiated or goal unknown)" : null,
      !hasUncommitted && !hasTrail ? "(No file changes or progress trail detected)" : null,
    ].filter(Boolean).join("\n");
    const metaSection = metaNotes ? `\n\n[Note: ${metaNotes}]` : "";
    const completionOutput = `[${sessionLabel(sessionType)} ${project}] [${mode}] Completion Output:\n\n${displayText}${metaSection}`;
    requiredParts = [guidance, completionOutput];
  }

  // Apply total message cap with guidance preservation (trim optional context first)
  const MAX_TOTAL_BODY_CHARS = 16000;
  const body = buildPrioritizedBody({
    requiredParts,
    optionalParts,
    maxChars: MAX_TOTAL_BODY_CHARS,
    log,
    scope: interactionPending ? "tmux-interaction-pending" : "tmux-completion",
  });

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
    _clawgateSource: interactionPending ? "tmux_interaction_pending" : "tmux_completion",
    _tmuxMode: mode,
  };

  log?.info?.(`clawgate: [${accountId}] tmux completion from "${project}" (mode=${mode}, prompt=${_promptMeta.hash}): "${text.slice(0, 80)}"`);

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
    let replyText = extractReplyText(replyPayload, log, "tmux_completion");
    if (!replyText.trim()) return;

    // Try <cc_read> — on-demand pane reading (any mode)
    const readResult = await tryExtractAndReadPane({ replyText, apiUrl, traceId, log });
    if (readResult) {
      if (readResult.error) {
        const msg = `[Pane read failed: ${readResult.error.message || readResult.error}]${readResult.lineText ? "\n\n" + readResult.lineText : ""}`;
        try { await sendLine(defaultConversation || project, msg); } catch {}
      } else {
        const header = `[Pane: ${readResult.project}]`;
        const content = readResult.paneContent || "(empty)";
        const msg = readResult.lineText
          ? `${readResult.lineText}\n\n${header}\n${content}`
          : `${header}\n${content}`;
        try { await sendLine(defaultConversation || project, msg); } catch {}
      }
      return;
    }

    if (interactionPending) {
      const hadChoiceTags = hasChoiceTags(replyText);
      replyText = stripChoiceTags(replyText);
      if (hadChoiceTags) {
        traceLog(log, "warn", {
          trace_id: traceId,
          stage: "interaction_pending_blocked",
          action: "cc_task_send",
          status: "ok",
          project,
          detail: interactionPending.reason,
        });
      }
      const advisory = normalizeLineReplyText(
        replyText || "Interactive prompt is waiting. Please choose an option in the terminal.",
        { project, sessionType, eventKind: "question" }
      );
      const shouldNotify = shouldNotifyInteractionPending({
        project,
        reason: interactionPending.reason,
        questionText: interactionPending.questionText,
        options: interactionPending.options || [],
      });
      if (!shouldNotify) {
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "interaction_pending",
          status: "suppressed",
          detail: "completion_advisory_dedup",
        });
        return;
      }
      try {
        await sendLine(defaultConversation || project, advisory);
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "interaction_pending",
          status: "sent",
          detail: interactionPending.reason,
        });
      } catch (err) {
        log?.error?.(`clawgate: [${accountId}] interaction pending advisory send failed: ${err}`);
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "interaction_pending",
          status: "failed",
          detail: String(err),
        });
      }
      return;
    }

    // Autonomous mode: try <cc_task> with round limiting
    if (mode === "autonomous") {
      const rounds = questionRoundMap.get(project) || 0;
      const MAX_ROUNDS = 3;

      if (rounds < MAX_ROUNDS) {
        const result = await tryExtractAndSendTask({
          replyText, project, apiUrl, traceId, log, mode,
        });
        if (result) {
          // LGTM termination: tryExtractAndSendTask intercepted before sending to CC
          if (result.terminated) {
            log?.info?.(`clawgate: [${accountId}] autonomous loop terminated by LGTM signal (project=${project}, round=${rounds + 1})`);
            clearTaskSendFailureStreak(result.targetProject || project);
            questionRoundMap.delete(project);
            setAutonomousLoopActive(project, false);
            setReviewDone(project, "lgtm_autonomous");
            log?.info?.(`clawgate: [${accountId}] review-done SET for "${project}" — completions suppressed until next task`);
            // Forward the review summary (lineText) to LINE as final milestone.
            if (result.lineText) {
              const normalized = normalizeLineReplyText(result.lineText, { project, sessionType, eventKind: "completion" });
              if (shouldSuppressAutonomousLine(normalized)) {
                logAutonomousLineEvent(log, {
                  accountId,
                  project,
                  reason: "final",
                  status: "suppressed",
                  detail: "low_value_final",
                });
                return;
              }
              try {
                await sendLine(defaultConversation || project, normalized);
                logAutonomousLineEvent(log, {
                  accountId,
                  project,
                  reason: "final",
                  status: "sent",
                  detail: `round=${rounds + 1}/${MAX_ROUNDS} signal=${result.taskText.trim()}`,
                });
              } catch (err) {
                log?.error?.(`clawgate: [${accountId}] autonomous final send failed: ${err}`);
                logAutonomousLineEvent(log, {
                  accountId,
                  project,
                  reason: "final",
                  status: "failed",
                  detail: String(err),
                });
              }
            } else {
              logAutonomousLineEvent(log, {
                accountId,
                project,
                reason: "final",
                status: "suppressed",
                detail: "no_line_text",
              });
            }
            return;
          }

          if (result.error) {
            const targetProject = result.targetProject || project;
            const errorCode = result.errorCode || "unknown_error";
            const errorMessage = result.error.message || String(result.error);
            const category = classifyTaskSendFailure({ errorCode, errorMessage });
            const eventName = `task_send_failed.${category}`;

            traceLog(log, "warn", {
              trace_id: traceId,
              stage: eventName,
              action: "cc_task_send",
              status: "failed",
              project: targetProject,
              error_code: errorCode,
            });

            if (category !== "other") {
              const streak = trackTaskSendFailureStreak({ project: targetProject, category });
              logAutonomousLineEvent(log, {
                accountId,
                project: targetProject,
                reason: "routing_error",
                status: "suppressed",
                detail: `${category} count=${streak.count}`,
              });
              if (category === "typing_busy" || category === "busy") {
                if (result.queued) {
                  logAutonomousLineEvent(log, {
                    accountId,
                    project: targetProject,
                    reason: "routing_error",
                    status: "suppressed",
                    detail: category === "busy"
                      ? (result.queuedDedup ? "busy_queued_dedup" : "busy_queued")
                      : (result.queuedDedup ? "typing_busy_queued_dedup" : "typing_busy_queued"),
                  });
                } else if (category === "typing_busy") {
                  const shouldNotifyTyping = shouldNotifyTaskSendError({
                    project: targetProject,
                    errorCode,
                    taskText: "",
                  });
                  if (shouldNotifyTyping) {
                    logAutonomousLineEvent(log, {
                      accountId,
                      project: targetProject,
                      reason: "routing_error",
                      status: "suppressed",
                      detail: "typing_busy",
                    });
                  } else {
                    logAutonomousLineEvent(log, {
                      accountId,
                      project: targetProject,
                      reason: "routing_error",
                      status: "suppressed",
                      detail: "typing_busy_dedup",
                    });
                  }
                } else if (result.lineText) {
                  const shouldForwardLine = shouldNotifyTaskSendError({
                    project: targetProject,
                    errorCode,
                    taskText: result.taskText || "",
                  });
                  if (shouldForwardLine) {
                    logAutonomousLineEvent(log, {
                      accountId,
                      project: targetProject,
                      reason: "routing_error",
                      status: "suppressed",
                      detail: "sanitized_fallback",
                    });
                  } else {
                    logAutonomousLineEvent(log, {
                      accountId,
                      project: targetProject,
                      reason: "routing_error",
                      status: "suppressed",
                      detail: "fallback_dedup",
                    });
                  }
                }
              } else if (result.lineText) {
                const shouldForwardLine = shouldNotifyTaskSendError({
                  project: targetProject,
                  errorCode,
                  taskText: result.taskText || "",
                });
                if (shouldForwardLine) {
                  logAutonomousLineEvent(log, {
                    accountId,
                    project: targetProject,
                    reason: "routing_error",
                    status: "suppressed",
                    detail: "sanitized_fallback",
                  });
                } else {
                  logAutonomousLineEvent(log, {
                    accountId,
                    project: targetProject,
                    reason: "routing_error",
                    status: "suppressed",
                    detail: "fallback_dedup",
                  });
                }
              }

              if (streak.shouldEscalate && category !== "typing_busy") {
                logAutonomousLineEvent(log, {
                  accountId,
                  project: targetProject,
                  reason: "routing_error",
                  status: "suppressed",
                  detail: `escalated ${Math.round(streak.streakDurationMs / 1000)}s`,
                });
                traceLog(log, "info", {
                  trace_id: traceId,
                  stage: "task_send_escalated",
                  action: "line_send",
                  status: "suppressed",
                  project: targetProject,
                  error_code: errorCode,
                  escalation_sec: Math.round(streak.streakDurationMs / 1000),
                });
              }
            } else {
              clearTaskSendFailureStreak(targetProject);
              const shouldNotify = shouldNotifyTaskSendError({
                project: targetProject,
                errorCode,
                taskText: result.taskText || "",
              });
              if (shouldNotify) {
                logAutonomousLineEvent(log, {
                  accountId,
                  project: targetProject,
                  reason: "routing_error",
                  status: "suppressed",
                  detail: "other_error",
                });
              } else {
                logAutonomousLineEvent(log, {
                  accountId,
                  project: targetProject,
                  reason: "routing_error",
                  status: "suppressed",
                  detail: errorCode,
                });
              }
            }
          } else {
            const nextRound = rounds + 1;
            questionRoundMap.set(project, nextRound);
            setAutonomousLoopActive(project, true);

            const riskDetected = hasAutonomousRiskSignal(result.taskText, result.lineText);
            const reason = riskDetected ? "risk" : "suppressed";

            if (reason === "suppressed") {
              logAutonomousLineEvent(log, {
                accountId,
                project,
                reason,
                status: "suppressed",
                detail: `round=${nextRound}/${MAX_ROUNDS}`,
              });
            } else {
              const milestone = autonomousMilestoneLine({
                reason,
                round: nextRound,
                maxRounds: MAX_ROUNDS,
                taskText: result.taskText,
                lineText: result.lineText,
              });
              const normalizedMilestone = normalizeLineReplyText(milestone, { project, sessionType, eventKind: "completion" });
              try {
                await sendLine(defaultConversation || project, normalizedMilestone);
                logAutonomousLineEvent(log, {
                  accountId,
                  project,
                  reason,
                  status: "sent",
                  detail: `round=${nextRound}/${MAX_ROUNDS}`,
                });
              } catch (err) {
                log?.error?.(`clawgate: [${accountId}] autonomous milestone send failed: ${err}`);
                logAutonomousLineEvent(log, {
                  accountId,
                  project,
                  reason,
                  status: "failed",
                  detail: String(err),
                });
              }
            }
          }
          return;
        }
      }
      // No <cc_task> or max rounds reached — reset counter, strip tags, fall through to LINE
      questionRoundMap.delete(project);
      setAutonomousLoopActive(project, false);
      log?.info?.(`clawgate: [${accountId}] autonomous loop reset for "${project}" — max rounds reached or no cc_task`);
      // Strip any <cc_task> tags so they don't leak raw into LINE
      replyText = replyText.replace(/<cc_task(?:\s+project="[^"]*")?>([\s\S]*?)<\/cc_task>/gi, "").trim();
    }

    // Auto mode: try <cc_task> (no round limiting)
    if (mode === "auto") {
      const result = await tryExtractAndSendTask({
        replyText, project, apiUrl, traceId, log, mode,
      });
      if (result) {
        // LGTM termination in auto mode — forward lineText, set review-done
        if (result.terminated) {
          clearTaskSendFailureStreak(result.targetProject || project);
          setReviewDone(result.targetProject || project, "lgtm_auto");
          log?.info?.(`clawgate: [${accountId}] review-done SET for "${result.targetProject || project}" — LGTM in auto mode`);
          if (result.lineText) {
            const normalized = normalizeLineReplyText(result.lineText, { project, sessionType, eventKind: "completion" });
            try { await sendLine(defaultConversation || project, normalized); } catch {}
          }
          return;
        }
        if (result.error) {
          const targetProject = result.targetProject || project;
          const errorCode = result.errorCode || "unknown_error";
          const errorMessage = result.error.message || String(result.error);
          const category = classifyTaskSendFailure({ errorCode, errorMessage });

          traceLog(log, "warn", {
            trace_id: traceId,
            stage: `task_send_failed.${category}`,
            action: "cc_task_send",
            status: "failed",
            project: targetProject,
            error_code: errorCode,
          });

          if (category !== "other") {
            const streak = trackTaskSendFailureStreak({ project: targetProject, category });
            log?.info?.(`clawgate: [${accountId}] auto task send benign failure suppressed (project=${targetProject}, category=${category}, count=${streak.count})`);
            if (category === "typing_busy") {
              if (result.queued) {
                log?.info?.(
                  `clawgate: [${accountId}] auto typing-busy task queued (project=${targetProject}, dedup=${result.queuedDedup ? 1 : 0})`
                );
              } else {
                const shouldNotifyTyping = shouldNotifyTaskSendError({
                  project: targetProject,
                  errorCode,
                  taskText: "",
                });
                if (shouldNotifyTyping) {
                  const advisory = normalizeLineReplyText(
                    buildTypingBusyAdvisoryLine(targetProject),
                    { project, sessionType, eventKind: "completion" }
                  );
                  try {
                    await sendLine(defaultConversation || project, advisory);
                  } catch (err) {
                    log?.error?.(`clawgate: [${accountId}] auto typing-busy advisory send failed: ${err}`);
                  }
                } else {
                  log?.info?.(`clawgate: [${accountId}] auto typing-busy advisory suppressed (project=${targetProject})`);
                }
              }
            } else if (result.lineText) {
              const shouldForwardLine = shouldNotifyTaskSendError({
                project: targetProject,
                errorCode,
                taskText: result.taskText || "",
              });
              if (shouldForwardLine) {
                const normalizedFallback = normalizeLineReplyText(result.lineText, { project, sessionType, eventKind: "completion" });
                try {
                  await sendLine(defaultConversation || project, normalizedFallback);
                } catch (err) {
                  log?.error?.(`clawgate: [${accountId}] auto fallback review send failed: ${err}`);
                }
              } else {
                log?.info?.(`clawgate: [${accountId}] auto benign fallback line suppressed (project=${targetProject}, code=${errorCode})`);
              }
            }
            if (streak.shouldEscalate && category !== "typing_busy") {
              const msg = buildTaskFailureEscalationLine({
                project: targetProject,
                category,
                streakDurationMs: streak.streakDurationMs,
              });
              try {
                await sendLine(defaultConversation || project, msg);
                traceLog(log, "info", {
                  trace_id: traceId,
                  stage: "task_send_escalated",
                  action: "line_send",
                  status: "ok",
                  project: targetProject,
                  error_code: errorCode,
                  escalation_sec: Math.round(streak.streakDurationMs / 1000),
                });
              } catch (err) {
                log?.error?.(`clawgate: [${accountId}] auto escalation send failed: ${err}`);
              }
            }
          } else {
            clearTaskSendFailureStreak(targetProject);
            const shouldNotify = shouldNotifyTaskSendError({
              project: targetProject,
              errorCode,
              taskText: result.taskText || "",
            });
            if (shouldNotify) {
              const msg = buildTaskFailureMessage(errorMessage, result.lineText, targetProject);
              try { await sendLine(defaultConversation || project, msg); } catch (err) {
                log?.error?.(`clawgate: [${accountId}] send error notice to LINE failed: ${err}`);
              }
            } else {
              log?.info?.(`clawgate: [${accountId}] task send error notice suppressed (project=${targetProject}, code=${errorCode})`);
            }
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
    if (mode === "autonomous" && shouldSuppressAutonomousLine(lineText)) {
      logAutonomousLineEvent(log, {
        accountId,
        project,
        reason: "final",
        status: "suppressed",
        detail: "low_value_final",
      });
      return;
    }
    log?.info?.(`clawgate: [${accountId}] sending tmux result to LINE "${defaultConversation}": "${lineText.slice(0, 80)}"`);
    try {
      await sendLine(defaultConversation || project, lineText);
      if (mode === "autonomous") {
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "final",
          status: "sent",
        });
      }
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] send tmux result to LINE failed: ${err}`);
      if (mode === "autonomous") {
        logAutonomousLineEvent(log, {
          accountId,
          project,
          reason: "final",
          status: "failed",
          detail: String(err),
        });
      }
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

  // Load prompt profiles (core + optional overlays) once
  const promptOptions = resolvePromptOptions(account.config);
  await loadPrompts(log, promptOptions);
  log?.info?.(
    `clawgate: [${accountId}] prompt profile version=${_promptMeta.version} hash=${_promptMeta.hash} validation=${_promptMeta.validationEnabled} layers=${_promptMeta.layers.join(" -> ")}`
  );

  // Set configurable display name filter (replaces hardcoded "Test User")
  _filterDisplayName = account.config?.filterDisplayName || "";
  projectViewReaders.set(accountId, createProjectViewReader(account.config?.projectView, log));

  log?.info?.(`clawgate: [${accountId}] starting gateway (apiUrl=${apiUrl}, poll=${pollIntervalMs}ms, defaultConv="${defaultConversation}")`);

  // Wait for ClawGate to be reachable
  await waitForReady(apiUrl, abortSignal, log);
  if (abortSignal?.aborted) {
    projectViewReaders.delete(accountId);
    return;
  }

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

  const enableLineBurstCoalesce = ENABLE_LINE_BURST_COALESCE && LINE_BURST_COALESCE_WINDOW_MS > 0;
  /** @type {Map<string, { conversation: string, firstAt: number, lastAt: number, timer: any, entries: Array<{ event: any, eventText: string, traceId: string, upstreamEventId: string, source: string, latencyFields: Record<string, number> }> }>} */
  const lineBurstBuffers = new Map();

  const flushLineBurstBuffer = async (key, trigger = "timer") => {
    const buffer = lineBurstBuffers.get(key);
    if (!buffer) return;
    lineBurstBuffers.delete(key);
    if (buffer.timer) clearTimeout(buffer.timer);

    const entries = buffer.entries;
    if (!entries || entries.length === 0) return;

    const latestEntry = entries[entries.length - 1];
    const firstEntry = entries[0];
    const mergedText = mergeLineBurstTexts(entries.map((entry) => entry.eventText)) || latestEntry.eventText;
    const mergedTraceId = `${latestEntry.traceId}-c${entries.length}`;
    const baseEvent = {
      ...latestEntry.event,
      payload: {
        ...(latestEntry.event?.payload || {}),
      },
    };
    baseEvent.payload.text = mergedText;
    baseEvent.payload.trace_id = mergedTraceId;
    baseEvent.payload.coalesced = entries.length > 1 ? "1" : "0";
    baseEvent.payload.coalesce_count = String(entries.length);
    baseEvent.payload.coalesce_window_ms = String(Math.max(0, buffer.lastAt - buffer.firstAt));
    baseEvent.payload.coalesce_trigger = trigger;
    baseEvent.payload.coalesce_first_trace_id = firstEntry.traceId;
    baseEvent.payload.coalesce_upstream_ids = entries.map((entry) => entry.upstreamEventId).filter(Boolean).join(",");

    traceLog(log, "info", {
      trace_id: mergedTraceId,
      stage: "ingress_coalesced",
      action: "dispatch_inbound_message",
      status: "ok",
      source: latestEntry.source,
      adapter: baseEvent.adapter || "line",
      conversation: buffer.conversation,
      coalesce_count: entries.length,
      coalesce_window_ms: Math.max(0, buffer.lastAt - buffer.firstAt),
      coalesce_trigger: trigger,
      upstream_event_ids: entries.map((entry) => entry.upstreamEventId).filter(Boolean).join(","),
      event_text_len: mergedText.length,
      event_text_head: dedupTextHead(mergedText),
      ...(latestEntry.latencyFields || {}),
    });

    try {
      await handleInboundMessage({
        event: baseEvent,
        accountId,
        apiUrl,
        cfg,
        defaultConversation,
        log,
      });
    } catch (err) {
      log?.error?.(`clawgate: [${accountId}] handleInboundMessage failed after coalesce: ${err}`);
      traceLog(log, "error", {
        trace_id: mergedTraceId,
        stage: "gateway_forward_failed",
        action: "handle_inbound_message",
        status: "failed",
        error: String(err),
      });
    }
  };

  const enqueueLineBurstEvent = ({
    event,
    eventText,
    traceId,
    conversation,
    source,
    upstreamEventId,
    latencyFields,
  }) => {
    if (!enableLineBurstCoalesce || event.adapter !== "line") return false;
    const key = `${accountId}::${conversation || ""}`;
    const now = Date.now();
    const clonedEvent = {
      ...event,
      payload: {
        ...(event.payload || {}),
      },
    };

    let buffer = lineBurstBuffers.get(key);
    if (!buffer) {
      buffer = {
        conversation,
        firstAt: now,
        lastAt: now,
        timer: null,
        entries: [],
      };
      lineBurstBuffers.set(key, buffer);
    }
    buffer.lastAt = now;
    buffer.entries.push({
      event: clonedEvent,
      eventText,
      traceId,
      upstreamEventId,
      source,
      latencyFields: latencyFields || {},
    });
    if (buffer.timer) clearTimeout(buffer.timer);
    buffer.timer = setTimeout(() => {
      void flushLineBurstBuffer(key, "timer");
    }, LINE_BURST_COALESCE_WINDOW_MS);

    traceLog(log, "debug", {
      trace_id: traceId,
      stage: "ingress_buffered",
      action: "coalesce_wait",
      status: "queued",
      adapter: event.adapter || "line",
      source,
      conversation,
      coalesce_count: buffer.entries.length,
      coalesce_window_ms: LINE_BURST_COALESCE_WINDOW_MS,
      upstream_event_id: upstreamEventId,
      event_text_len: eventText.length,
      event_text_head: dedupTextHead(eventText),
      ...(latencyFields || {}),
    });
    return true;
  };

  // Polling loop
  while (!abortSignal?.aborted) {
    try {
      await flushPendingTaskQueue({
        apiUrl,
        traceId: makeTraceId("task-queue-flush"),
        log,
      });
    } catch (err) {
      log?.warn?.(`clawgate: [${accountId}] task queue flush failed (pre-poll): ${err}`);
    }

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
          const source = event.payload?.source || "poll";
          const ingressOrigin = inferIngressOrigin(event.adapter, source);
          const upstreamEventId = `${event?.id ?? ""}`;
          const ingressAgeMs = Math.max(0, Date.now() - eventTimestamp(event));
          const ingressLatencyFields = {
            ingress_age_ms: ingressAgeMs,
          };
          const lineWatchCaptureMs = parseOptionalMs(event.payload?.line_watch_capture_ms);
          const lineWatchSignalCollectMs = parseOptionalMs(event.payload?.line_watch_signal_collect_ms);
          const lineWatchFusionMs = parseOptionalMs(event.payload?.line_watch_fusion_ms);
          const lineWatchTotalDetectMs = parseOptionalMs(event.payload?.line_watch_total_detect_ms);
          if (lineWatchCaptureMs !== undefined) ingressLatencyFields.line_watch_capture_ms = lineWatchCaptureMs;
          if (lineWatchSignalCollectMs !== undefined) ingressLatencyFields.line_watch_signal_collect_ms = lineWatchSignalCollectMs;
          if (lineWatchFusionMs !== undefined) ingressLatencyFields.line_watch_fusion_ms = lineWatchFusionMs;
          if (lineWatchTotalDetectMs !== undefined) ingressLatencyFields.line_watch_total_detect_ms = lineWatchTotalDetectMs;
          traceLog(log, "info", {
            trace_id: traceId,
            stage: "ingress_received",
            action: "poll_event",
            status: "ok",
            adapter: event.adapter || "unknown",
            source,
            ingress_origin: ingressOrigin,
            upstream_event_id: upstreamEventId,
            ...ingressLatencyFields,
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
            if (clearInteractionPending(proj)) {
              log?.info?.(`clawgate: [${accountId}] interaction_pending CLEARED for "${proj}" — progress detected`);
            }
            if (clearReviewDone(proj)) {
              log?.info?.(`clawgate: [${accountId}] review-done CLEARED for "${proj}" — progress detected (new work started)`);
            }
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

          const conversation = event.payload?.conversation || "";
          const rawEventText = event.payload?.text || "";
          const eventText = normalizeInboundText(rawEventText, source);
          const commonDedupKey = buildCommonIngressDedupKey({
            adapter: event.adapter || "unknown",
            conversation,
            eventText,
          });
          const shortLineDedupKey = buildShortLineIngressDedupKey({
            adapter: event.adapter || "unknown",
            conversation,
            eventText,
            source,
          });

          // Skip only near-empty texts; keep short Japanese lines for recall.
          if (eventText.trim().length < MIN_TEXT_LENGTH) {
            log?.debug?.(`clawgate: [${accountId}] skipped short/noisy text (raw=${rawEventText.length}, clean=${eventText.length})`);
            traceLog(log, "info", {
              trace_id: traceId,
              stage: "ingress_dropped",
              action: "sanitize",
              status: "suppressed",
              reason: "too_short",
              raw_len: rawEventText.length,
              clean_len: eventText.length,
              ingress_origin: ingressOrigin,
              dedup_key: commonDedupKey.keyHash || "",
              ...ingressLatencyFields,
            });
            continue;
          }

          // Plugin-level echo suppression (ClawGate's 8s window is too short for AI replies)
          if (isPluginEcho(eventText)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed echo: "${eventText.slice(0, 60)}"`);
            traceLog(log, "info", {
              trace_id: traceId,
              stage: "ingress_dropped",
              action: "echo_guard",
              status: "suppressed",
              reason: "plugin_echo",
              ingress_origin: ingressOrigin,
              dedup_key: commonDedupKey.keyHash || "",
              ...ingressLatencyFields,
            });
            continue;
          }

          const shortLineDedupResult = matchShortLineIngressDuplicate(shortLineDedupKey);
          if (shortLineDedupResult.hit) {
            log?.debug?.(`clawgate: [${accountId}] suppressed short-line duplicate: "${eventText.slice(0, 60)}"`);
            traceLog(log, "info", {
              trace_id: traceId,
              stage: "ingress_dropped",
              action: "dedup",
              status: "suppressed",
              reason: "short_line_dedup",
              dedup_hit: true,
              dedup_reason: shortLineDedupResult.reason,
              dedup_window_sec: Math.floor(SHORT_LINE_DEDUP_WINDOW_MS / 1000),
              dedup_key: shortLineDedupKey.keyHash || "",
              event_text_len: eventText.length,
              event_text_head: dedupTextHead(eventText),
              ingress_origin: ingressOrigin,
              ...ingressLatencyFields,
            });
            continue;
          }

          const commonDedupResult = matchCommonIngressDuplicate(commonDedupKey);
          if (commonDedupResult.hit) {
            log?.debug?.(`clawgate: [${accountId}] suppressed common dedup (${commonDedupResult.reason}): "${eventText.slice(0, 60)}"`);
            traceLog(log, "info", {
              trace_id: traceId,
              stage: "ingress_dropped",
              action: "dedup",
              status: "suppressed",
              reason: "common_dedup",
              dedup_hit: true,
              dedup_reason: commonDedupResult.reason,
              dedup_window_sec: Math.floor(COMMON_INGRESS_DEDUP_WINDOW_MS / 1000),
              dedup_key: commonDedupKey.keyHash || "",
              ingress_origin: ingressOrigin,
              ...ingressLatencyFields,
            });
            continue;
          }

          // Cross-source deduplication (AXRow / PixelDiff / NotificationBanner)
          if (isDuplicateInbound(eventText)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed duplicate: "${eventText.slice(0, 60)}"`);
            traceLog(log, "info", {
              trace_id: traceId,
              stage: "ingress_dropped",
              action: "dedup",
              status: "suppressed",
              reason: "duplicate_window",
              dedup_hit: true,
              dedup_reason: "duplicate_window",
              dedup_window_sec: Math.floor(activeDedupWindowMs() / 1000),
              dedup_key: commonDedupKey.keyHash || "",
              ingress_origin: ingressOrigin,
              ...ingressLatencyFields,
            });
            continue;
          }
          if (isStaleRepeatInbound(eventText, conversation, source)) {
            log?.debug?.(`clawgate: [${accountId}] suppressed stale repeat: "${eventText.slice(0, 60)}"`);
            traceLog(log, "info", {
              trace_id: traceId,
              stage: "ingress_dropped",
              action: "dedup",
              status: "suppressed",
              reason: "stale_repeat",
              dedup_hit: true,
              dedup_reason: "stale_repeat",
              dedup_window_sec: Math.floor(activeStaleRepeatWindowMs() / 1000),
              dedup_key: commonDedupKey.keyHash || "",
              ingress_origin: ingressOrigin,
              ...ingressLatencyFields,
            });
            continue;
          }

          // Record before dispatch so subsequent duplicates are caught
          recordInbound(eventText);
          recordStableInbound(eventText, conversation);
          recordShortLineIngress(shortLineDedupKey);
          recordCommonIngress(commonDedupKey);
          if (event.payload) {
            event.payload.text = eventText;
          }
          traceLog(log, "info", {
            trace_id: traceId,
            stage: "ingress_accepted",
            action: "dispatch_inbound_message",
            status: "ok",
            source,
            conversation,
            dedup_hit: false,
            dedup_reason: "none",
            dedup_window_sec: Math.floor(COMMON_INGRESS_DEDUP_WINDOW_MS / 1000),
            dedup_key: commonDedupKey.keyHash || "",
            short_dedup_key: shortLineDedupKey.keyHash || "",
            event_text_len: eventText.length,
            event_text_head: dedupTextHead(eventText),
            ingress_origin: ingressOrigin,
            upstream_event_id: upstreamEventId,
            ...ingressLatencyFields,
          });

          if (enqueueLineBurstEvent({
            event,
            eventText,
            traceId,
            conversation,
            source,
            upstreamEventId,
            latencyFields: ingressLatencyFields,
          })) {
            continue;
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
              ...ingressLatencyFields,
            });
          }
        }
        cursor = poll.next_cursor ?? cursor;
      }
    } catch (err) {
      if (abortSignal?.aborted) break;
      log?.error?.(`clawgate: [${accountId}] poll error: ${err}`);
    }

    try {
      await flushPendingTaskQueue({
        apiUrl,
        traceId: makeTraceId("task-queue-flush"),
        log,
      });
    } catch (err) {
      log?.warn?.(`clawgate: [${accountId}] task queue flush failed (post-poll): ${err}`);
    }

    await sleep(pollIntervalMs, abortSignal);
  }

  if (lineBurstBuffers.size > 0) {
    const pendingKeys = [...lineBurstBuffers.keys()];
    for (const key of pendingKeys) {
      await flushLineBurstBuffer(key, "shutdown");
    }
  }

  try {
    await flushPendingTaskQueue({
      apiUrl,
      traceId: makeTraceId("task-queue-flush"),
      log,
    });
  } catch (err) {
    log?.warn?.(`clawgate: [${accountId}] task queue flush failed (shutdown): ${err}`);
  }

  projectViewReaders.delete(accountId);
  log?.info?.(`clawgate: [${accountId}] gateway stopped`);
}

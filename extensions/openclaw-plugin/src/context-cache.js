/**
 * context-cache.js — TTL cache for project context and path resolution.
 *
 * Two-layer context management:
 *   - Stable context: cached with TTL + hash-based dedup via sentHash
 *   - Dynamic envelope: always built fresh (no caching)
 *   - Path resolution: uses tmux pane_current_path via client.resolveTmuxWorkingDir()
 */

import {
  buildProjectContext,
  buildProjectRoster,
  buildStableContext,
  buildDynamicEnvelope,
} from "./context-reader.js";
import { resolveTmuxWorkingDir } from "./client.js";

const TTL_MS = 5 * 60 * 1000; // 5 minutes

/**
 * @typedef {{ context: string, hash: string, resolvedAt: number }} CacheEntry
 */

/** @type {Map<string, CacheEntry>} */
const contextCache = new Map();

/** @type {Map<string, string>} project name -> absolute path */
const pathCache = new Map();

/** @type {Map<string, string>} project -> last sent hash */
const sentHash = new Map();

/** @type {Map<string, { text: string, timestamp: number }>} */
const progressSnapshots = new Map();

// ── Task goal tracking (remembers what the reviewer agent asked CC to do) ────
/** @type {Map<string, string>} project -> task goal text */
const taskGoals = new Map();

// ── Progress trail (accumulated for completion context) ──────────
/** @type {Map<string, { entries: string[], timestamps: number[] }>} */
const progressTrails = new Map();
const MAX_TRAIL_ENTRIES = 6;
const MAX_TRAIL_CHARS = 2000;

/**
 * Resolve and cache the working directory for a project via tmux.
 * @param {string} project — project name
 * @param {string} [tmuxTarget] — tmux target pane (e.g. "clawgate:0.0")
 * @returns {string|null}
 */
export function resolveProjectPath(project, tmuxTarget) {
  // If we already have a cached path, return it
  if (pathCache.has(project)) return pathCache.get(project);

  // Try to resolve via tmux
  if (tmuxTarget) {
    const path = resolveTmuxWorkingDir(tmuxTarget);
    if (path) {
      pathCache.set(project, path);
      return path;
    }
  }

  return null;
}

/**
 * Get project context, using cache if fresh.
 * (Backward-compatible: returns combined stable + dynamic context)
 * @param {string} project — project name
 * @param {string} [tmuxTarget] — tmux target pane
 * @returns {string|null} — context string or null if path can't be resolved
 */
export function getProjectContext(project, tmuxTarget) {
  const path = resolveProjectPath(project, tmuxTarget);
  if (!path) return null;

  const now = Date.now();
  const cached = contextCache.get(project);

  if (cached && now - cached.resolvedAt < TTL_MS) {
    return cached.context;
  }

  // Build fresh context
  const { context, hash } = buildProjectContext(path);
  contextCache.set(project, { context, hash, resolvedAt: now });
  return context;
}

/**
 * Get stable context with hash-based dedup.
 * Returns isNew=true if the hash differs from the last sent hash.
 *
 * @param {string} project — project name
 * @param {string} [tmuxTarget] — tmux target pane
 * @returns {{ context: string, hash: string, isNew: boolean } | null}
 */
export function getStableContext(project, tmuxTarget) {
  const path = resolveProjectPath(project, tmuxTarget);
  if (!path) return null;

  const { context, hash } = buildStableContext(path);
  const lastHash = sentHash.get(project);
  const isNew = lastHash !== hash;

  return { context, hash, isNew };
}

/**
 * Get fresh dynamic envelope (always rebuilt, never cached).
 *
 * @param {string} project — project name
 * @param {string} [tmuxTarget] — tmux target pane
 * @returns {{ envelope: string } | null}
 */
export function getDynamicEnvelope(project, tmuxTarget) {
  const path = resolveProjectPath(project, tmuxTarget);
  if (!path) return null;

  return buildDynamicEnvelope(path);
}

/**
 * Mark a stable context hash as sent (call after successful dispatch).
 * @param {string} project
 * @param {string} hash
 */
export function markContextSent(project, hash) {
  sentHash.set(project, hash);
}

/**
 * Build a compact roster of all known projects.
 * Uses pathCache to list projects we've seen.
 * @param {Map<string, string>} [sessionModes] — project -> mode mapping
 * @param {Map<string, string>} [sessionStatuses] — project -> status mapping
 * @param {Map<string, { questionText: string }>} [pendingQuestions] — project -> pending question
 * @returns {string}
 */
export function getProjectRoster(sessionModes, sessionStatuses, pendingQuestions) {
  if (pathCache.size === 0) return "";

  const projects = [];
  for (const [name, path] of pathCache) {
    const mode = sessionModes?.get(name) || "unknown";
    // Only include observe/autonomous projects in roster
    if (mode === "ignore") continue;
    const status = sessionStatuses?.get(name) || "unknown";
    const pending = pendingQuestions?.get(name);
    const pendingQuestion = pending ? pending.questionText : undefined;
    const progress = progressSnapshots.get(name);
    const progressText = progress ? progress.text : undefined;
    projects.push({ name, path, mode, status, pendingQuestion, progressText });
  }

  if (!projects.length) return "";
  return buildProjectRoster(projects);
}

/**
 * Store a progress snapshot for a running project.
 * @param {string} project
 * @param {string} text
 */
export function setProgressSnapshot(project, text) {
  progressSnapshots.set(project, { text, timestamp: Date.now() });
}

/**
 * Get the current progress snapshot for a project.
 * @param {string} project
 * @returns {{ text: string, timestamp: number } | null}
 */
export function getProgressSnapshot(project) {
  return progressSnapshots.get(project) || null;
}

/**
 * Clear a progress snapshot (e.g. on task completion).
 * @param {string} project
 */
export function clearProgressSnapshot(project) {
  progressSnapshots.delete(project);
}

// ── Progress noise filtering ─────────────────────────────────
// tmux captures include Claude Code's status bar, separators, spinners, etc.
// We strip these to keep only meaningful work descriptions.
const PROGRESS_NOISE_PATTERNS = [
  /[▁▂▃▄▅▆▇█░▒▓]{2,}/,         // bar chart / meters
  /⏵⏵/,                          // mode indicator play buttons
  /shift\+tab/i,                  // keyboard hint
  /^[─━═\s]{3,}$/,               // separator lines
  /\[Op\d/,                       // model indicator [Op4.6]
  /accept edits/i,                // mode indicator text
  /running stop hooks/i,          // internal CC lifecycle
  /^\s*❯\s*[─━]*\s*$/,           // empty prompt line
  /\[message_id:/i,               // internal tracking
  /\d+[.\d]*[kK]\s*tokens?\s*·/i, // token stats
  /^\s*[✢✳·]\s*(Mus|Synth|Think|Mosey)/i, // spinner-only lines
  /^\s*C:\s*[█▒░]+/,             // context meter
  /^\s*S:\s*[█▒░]+/,             // spending meter
  /^\s*B:\s*[▁▂▃▄▅▆▇█]+/,       // bandwidth meter
  /💬\d+/,                        // message count badge
  /\d+[KMG]\/\d+[KMG]/,          // context size "81.2K/160K"
  /^\s*\d+[hm]\d*[ms]?$/,        // duration "1h28m"
  /ctrl\+o to expand/i,           // UI hint
];

function isProgressNoiseLine(line) {
  const s = line.trim();
  if (!s) return true;
  if (s.length < 4) return true;
  return PROGRESS_NOISE_PATTERNS.some((p) => p.test(s));
}

/**
 * Filter UI noise from raw pane output while preserving structure.
 * Unlike extractMeaningfulProgress (which keeps only 3 lines),
 * this preserves all meaningful lines.
 * @param {string} text
 * @returns {string}
 */
export function filterPaneNoise(text) {
  if (!text) return "";
  return text.split("\n")
    .filter(l => !isProgressNoiseLine(l))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/**
 * Remove trail entries whose content appears in referenceText.
 * Returns cleaned trail string, or null if nothing remains.
 * @param {string} trail
 * @param {string} referenceText
 * @returns {string|null}
 */
export function deduplicateTrailAgainst(trail, referenceText) {
  if (!trail || !referenceText) return trail;
  const refLines = new Set(
    referenceText.split("\n").map(l => l.trim()).filter(Boolean)
  );
  const entries = trail.split("\n---\n");
  const kept = entries.filter(entry => {
    const lines = entry.split("\n").map(l => l.trim()).filter(Boolean);
    if (lines.length === 0) return false;
    // Drop entry if >50% of its lines appear in reference
    const matchCount = lines.filter(l => refLines.has(l)).length;
    return matchCount / lines.length < 0.5;
  });
  return kept.length > 0 ? kept.join("\n---\n") : null;
}

/**
 * Cap text to maxChars. strategy: "tail" keeps end, "head" keeps start.
 * @param {string} text
 * @param {number} maxChars
 * @param {"tail"|"head"} [strategy="tail"]
 * @returns {string}
 */
export function capText(text, maxChars, strategy = "tail") {
  if (!text || text.length <= maxChars) return text;
  if (strategy === "tail") {
    return "...(truncated)\n" + text.slice(-maxChars);
  }
  return text.slice(0, maxChars) + "\n...(truncated)";
}

/**
 * Extract meaningful lines from tmux progress text, stripping UI chrome.
 * @param {string} text
 * @returns {string}
 */
function extractMeaningfulProgress(text) {
  if (!text) return "";
  const lines = text.split("\n").filter(Boolean);
  const meaningful = lines.filter((l) => !isProgressNoiseLine(l));
  if (!meaningful.length) return "";
  // Keep last 3 meaningful lines as a compact summary
  return meaningful.slice(-3).join("\n");
}

/**
 * Append a progress entry to the trail for a project.
 * Keeps last MAX_TRAIL_ENTRIES entries, total MAX_TRAIL_CHARS.
 * Only stores meaningful content (UI noise is stripped).
 * @param {string} project
 * @param {string} text
 */
export function appendProgressTrail(project, text) {
  if (!text?.trim()) return;
  const summary = extractMeaningfulProgress(text);
  if (!summary) return; // all noise, skip
  let trail = progressTrails.get(project);
  if (!trail) {
    trail = { entries: [], timestamps: [] };
    progressTrails.set(project, trail);
  }
  // Dedup: skip if identical to the last entry
  if (trail.entries.length > 0 && trail.entries[trail.entries.length - 1] === summary) {
    return;
  }
  trail.entries.push(summary);
  trail.timestamps.push(Date.now());
  while (trail.entries.length > MAX_TRAIL_ENTRIES) {
    trail.entries.shift();
    trail.timestamps.shift();
  }
}

/**
 * Get accumulated progress trail for a project.
 * @param {string} project
 * @returns {string|null}
 */
export function getProgressTrail(project) {
  const trail = progressTrails.get(project);
  if (!trail || !trail.entries.length) return null;
  let result = trail.entries.join("\n---\n");
  if (result.length > MAX_TRAIL_CHARS) {
    result = "...(truncated)\n" + result.slice(-MAX_TRAIL_CHARS);
  }
  return result;
}

/**
 * Clear accumulated progress trail (call after completion dispatch).
 * @param {string} project
 */
export function clearProgressTrail(project) {
  progressTrails.delete(project);
}

/**
 * Store the task goal that the reviewer agent sent to CC via <cc_task>.
 * Used at completion time to compare goal vs result.
 * @param {string} project
 * @param {string} goalText
 */
export function setTaskGoal(project, goalText) {
  if (!goalText?.trim()) return;
  taskGoals.set(project, goalText.trim());
}

/**
 * Get the current task goal for a project (if any).
 * @param {string} project
 * @returns {string|null}
 */
export function getTaskGoal(project) {
  return taskGoals.get(project) || null;
}

/**
 * Clear the task goal (e.g. after completion dispatch).
 * @param {string} project
 */
export function clearTaskGoal(project) {
  taskGoals.delete(project);
}

/**
 * Invalidate cache for a project (e.g. after task completion).
 * Path cache is preserved — only context is invalidated.
 * sentHash is NOT cleared (AI conversation still has the old context).
 * @param {string} project
 */
export function invalidateProject(project) {
  contextCache.delete(project);
}

/**
 * Get all known project paths (for roster building).
 * @returns {Map<string, string>}
 */
export function getKnownProjects() {
  return new Map(pathCache);
}

/**
 * Register a project path manually (e.g. from tmux session list).
 * @param {string} project
 * @param {string} path
 */
export function registerProjectPath(project, path) {
  pathCache.set(project, path);
}

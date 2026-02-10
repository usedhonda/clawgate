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
 * Clear a progress snapshot (e.g. on task completion).
 * @param {string} project
 */
export function clearProgressSnapshot(project) {
  progressSnapshots.delete(project);
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

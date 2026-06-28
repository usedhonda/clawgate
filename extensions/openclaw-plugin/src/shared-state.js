/**
 * Shared state bridge between gateway.js and outbound.js.
 * Allows gateway to register the active project for a conversation
 * so outbound.sendText can apply [CC project] or [Codex project] prefix.
 */

/** @type {Map<string, { project: string, sessionType: string, ts: number }>} */
const activeDispatchProjects = new Map();

/**
 * Register the active project for a conversation.
 * Called by gateway.js before dispatching tmux events.
 * @param {string} conversation
 * @param {string} project
 * @param {string} [sessionType="claude_code"]
 */
export function setActiveProject(conversation, project, sessionType = "claude_code") {
  if (!conversation || !project) return;
  activeDispatchProjects.set(conversation, { project, sessionType, ts: Date.now() });
  // Cleanup entries older than 60 seconds
  for (const [k, v] of activeDispatchProjects) {
    if (Date.now() - v.ts > 60_000) activeDispatchProjects.delete(k);
  }
}

/**
 * Get the active project for a conversation.
 * Called by outbound.js to apply prefix.
 * @param {string} conversation
 * @returns {{ project: string, sessionType: string }}
 */
export function getActiveProject(conversation) {
  if (!conversation) return { project: "", sessionType: "claude_code" };
  const entry = activeDispatchProjects.get(conversation);
  if (!entry) return { project: "", sessionType: "claude_code" };
  if (Date.now() - entry.ts > 60_000) {
    activeDispatchProjects.delete(conversation);
    return { project: "", sessionType: "claude_code" };
  }
  return { project: entry.project, sessionType: entry.sessionType };
}

/**
 * Clear the active project for a conversation.
 * Called by gateway.js before dispatching LINE inbound messages
 * to prevent tmux prefixes from leaking into regular replies.
 * @param {string} conversation
 */
export function clearActiveProject(conversation) {
  if (!conversation) return;
  activeDispatchProjects.delete(conversation);
}

/** @type {Map<string, string>} project -> resolved session mode (mirrored from gateway.js sessionModes) */
const sessionModeByProject = new Map();

/**
 * Mirror a project's resolved session mode so outbound.sendText can route
 * dev-lane (autonomous/auto tmux) replies back to the CC session pane instead
 * of the user's LINE. Called by gateway.js whenever a project's mode is
 * (re)computed (recomputeProjectMode).
 * @param {string} project
 * @param {string} mode
 */
export function setSessionMode(project, mode) {
  const p = `${project || ""}`.trim();
  if (!p) return;
  sessionModeByProject.set(p, `${mode || "ignore"}`.trim().toLowerCase() || "ignore");
}

/**
 * Get a project's resolved session mode ("ignore" when unknown).
 * Called by outbound.js to decide pane (autonomous/auto) vs LINE (observe/other).
 * @param {string} project
 * @returns {string}
 */
export function getSessionMode(project) {
  const p = `${project || ""}`.trim();
  if (!p) return "ignore";
  return sessionModeByProject.get(p) || "ignore";
}

/** @type {((entry: { project: string, text: string, mode: string, traceId: string }) => boolean) | null} */
let devLaneEnqueueFn = null;

/**
 * Register the dev-lane enqueue implementation. Called once by gateway.js at
 * startup so outbound.js can hand a busy (retriable 503) pane redirect off to
 * the same pendingTaskQueue + flushPendingTaskQueue retry machinery the cc_task
 * loop uses, without outbound.js importing gateway.js (avoids circular import).
 * @param {(entry: { project: string, text: string, mode: string, traceId: string }) => boolean} fn
 */
export function registerDevLaneEnqueue(fn) {
  devLaneEnqueueFn = typeof fn === "function" ? fn : null;
}

/**
 * Queue an already-prefixed dev-lane redirect for idle retry via the registered
 * enqueue impl. Returns false when no impl is registered (fail-safe: caller then
 * surfaces the original send failure instead of silently dropping the reply).
 * @param {{ project: string, text: string, mode: string, traceId?: string }} entry
 * @returns {boolean} true when queued, false when no enqueue impl is registered
 */
export function enqueueDevLaneText({ project, text, mode, traceId = "" } = {}) {
  if (!devLaneEnqueueFn) return false;
  const p = `${project || ""}`.trim();
  const t = `${text || ""}`;
  if (!p || !t) return false;
  try {
    return devLaneEnqueueFn({ project: p, text: t, mode: `${mode || ""}`, traceId: `${traceId || ""}` }) !== false;
  } catch {
    return false;
  }
}

// Remembered gate:direct origins. When an inbound carries a reply=session
// tprojHeader with a return_url, we remember {returnUrl, sender, workspace, mode}
// keyed by conversation, so Chi's async message-tool reply (which no longer has
// the header) can be routed back to the originating dev pane via the return_url
// instead of leaking to the user's LINE. Entries expire after the TTL.
const tprojOriginStore = new Map();
const TPROJ_ORIGIN_TTL_MS = 10 * 60 * 1000;

/**
 * Remember a gate:direct origin keyed by conversation.
 * @param {string} conversation  e.g. "tproj"
 * @param {{ returnUrl: string, sender: string, workspace: string, mode?: string }} origin
 */
export function rememberTprojOrigin(conversation, { returnUrl, sender, workspace, mode } = {}) {
  if (!conversation || !returnUrl || !sender || !workspace) return;
  tprojOriginStore.set(`${conversation}`, {
    returnUrl, sender, workspace, mode: mode || "autonomous", ts: Date.now(),
  });
}

/**
 * Look up a live (within TTL) remembered origin for a conversation; null if none.
 * @param {string} conversation
 * @returns {{ returnUrl: string, sender: string, workspace: string, mode: string } | null}
 */
export function lookupTprojOrigin(conversation) {
  if (!conversation) return null;
  const rec = tprojOriginStore.get(`${conversation}`);
  if (!rec) return null;
  if (Date.now() - rec.ts > TPROJ_ORIGIN_TTL_MS) {
    tprojOriginStore.delete(`${conversation}`);
    return null;
  }
  return rec;
}

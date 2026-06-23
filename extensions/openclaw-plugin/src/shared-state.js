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

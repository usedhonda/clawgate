/**
 * project-view.js — read-only project docs bridge for Observe/Autonomous context.
 *
 * Uses an external wrapper command (default: project-context-read) that is expected
 * to enforce read-only boundaries on the host side.
 */

import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { sep } from "node:path";

const DEFAULT_COMMAND = "project-context-read";
const DEFAULT_ROOT_PREFIX = `${homedir()}/projects`;
const DEFAULT_FILES = ["AGENTS.md", "CLAUDE.md", "README.md"];
const DEFAULT_TIMEOUT_MS = 2000;
const DEFAULT_TTL_MS = 90_000;
const DEFAULT_MAX_FILE_CHARS = 1600;
const DEFAULT_MAX_TOTAL_CHARS = 5000;
const DEFAULT_MAX_FILES = 3;

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function asStringArray(value, fallback = []) {
  if (!Array.isArray(value)) return fallback;
  return value
    .map((v) => `${v || ""}`.trim())
    .filter(Boolean);
}

function toInt(value, fallback, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const n = Number.parseInt(`${value ?? ""}`, 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function sanitizeText(raw) {
  return `${raw || ""}`
    .replace(/\r\n?/g, "\n")
    .replace(/\u0000/g, "")
    .trim();
}

function capText(text, maxChars) {
  if (!text || text.length <= maxChars) return text;
  if (maxChars <= 32) return text.slice(0, maxChars);
  return `${text.slice(0, maxChars - 15)}\n... (truncated)`;
}

function shellErrorSummary(err) {
  if (!err) return "unknown";
  if (err.code === "ENOENT") return "command_not_found";
  const stderr = sanitizeText(err.stderr);
  if (stderr) return stderr.split("\n")[0];
  const message = sanitizeText(err.message);
  if (message) return message.split("\n")[0];
  return "execution_failed";
}

function toProjectsRelativePath(absPath, rootPrefix) {
  const absolute = `${absPath || ""}`.trim();
  const root = `${rootPrefix || ""}`.trim().replace(/\/+$/, "");
  if (!absolute || !root) return "";
  const withSep = `${root}${sep}`;
  if (absolute === root) return "";
  if (!absolute.startsWith(withSep)) return "";
  return absolute.slice(withSep.length).replace(/^\//, "");
}

function noOpReader() {
  return {
    getContextBlock: () => "",
  };
}

export function createProjectViewReader(rawConfig = {}, log) {
  const cfg = asObject(rawConfig);
  const command = `${cfg.command || DEFAULT_COMMAND}`.trim() || DEFAULT_COMMAND;
  const rootPrefix = `${cfg.rootPrefix || DEFAULT_ROOT_PREFIX}`.trim() || DEFAULT_ROOT_PREFIX;
  const timeoutMs = toInt(cfg.timeoutMs, DEFAULT_TIMEOUT_MS, { min: 500, max: 10_000 });
  const ttlMs = toInt(cfg.ttlMs, DEFAULT_TTL_MS, { min: 10_000, max: 10 * 60_000 });
  const maxFileChars = toInt(cfg.maxFileChars, DEFAULT_MAX_FILE_CHARS, { min: 400, max: 4000 });
  const maxTotalChars = toInt(cfg.maxTotalChars, DEFAULT_MAX_TOTAL_CHARS, { min: 1000, max: 10_000 });
  const maxFiles = toInt(cfg.maxFiles, DEFAULT_MAX_FILES, { min: 1, max: 8 });
  const defaultFiles = asStringArray(cfg.defaultFiles, DEFAULT_FILES).slice(0, maxFiles);
  const projectRoots = asObject(cfg.projectRoots);
  const projectFiles = asObject(cfg.projectFiles);
  const projects = asObject(cfg.projects);
  const forceWhenStableExists = cfg.forceWhenStableExists === true;
  const enabled = cfg.enabled !== false;

  if (!enabled) {
    log?.info?.("clawgate: project_view disabled by config");
    return noOpReader();
  }

  let commandAvailable = null;
  let activeCommand = command;
  let commandErrorSummary = "";
  /** @type {Map<string, { block: string, expiresAt: number }>} */
  const cache = new Map();
  /** @type {Map<string, number>} */
  const rootMissLogAt = new Map();
  const ROOT_MISS_LOG_COOLDOWN_MS = 60_000;

  const runReadCommand = (args) => execFileSync(activeCommand, args, {
    encoding: "utf-8",
    timeout: timeoutMs,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const ensureCommandAvailable = () => {
    if (commandAvailable === true) return true;
    if (commandAvailable === false) return false;
    try {
      runReadCommand(["list"]);
      commandAvailable = true;
      log?.info?.(`clawgate: project_view command ready (${activeCommand})`);
      return true;
    } catch (err) {
      commandAvailable = false;
      commandErrorSummary = shellErrorSummary(err);
      log?.warn?.(`clawgate: project_view disabled (command check failed: ${commandErrorSummary})`);
      return false;
    }
  };

  const resolveProjectRoot = ({ project, resolvedProjectPath }) => {
    const projectKey = `${project || ""}`.trim();
    const scoped = asObject(projects[projectKey]);
    const scopedRoot = `${scoped.root || ""}`.trim();
    if (scopedRoot) return scopedRoot.replace(/^\/+/, "");

    const mappedRoot = `${projectRoots[projectKey] || ""}`.trim();
    if (mappedRoot) return mappedRoot.replace(/^\/+/, "");

    const derived = toProjectsRelativePath(resolvedProjectPath, rootPrefix);
    if (derived) return derived.replace(/^\/+/, "");

    return "";
  };

  const resolveProjectFiles = (project) => {
    const projectKey = `${project || ""}`.trim();
    const scoped = asObject(projects[projectKey]);
    const scopedFiles = asStringArray(scoped.files);
    if (scopedFiles.length > 0) return scopedFiles.slice(0, maxFiles);

    const mappedFiles = asStringArray(projectFiles[projectKey]);
    if (mappedFiles.length > 0) return mappedFiles.slice(0, maxFiles);

    return (defaultFiles.length > 0 ? defaultFiles : DEFAULT_FILES).slice(0, maxFiles);
  };

  const readOneFile = (root, relPath) => {
    const normalizedRel = `${relPath || ""}`.trim().replace(/^\/+/, "");
    if (!normalizedRel) return "";
    const full = `${root}/${normalizedRel}`.replace(/\/+/g, "/");
    try {
      const raw = runReadCommand(["read", full]);
      return sanitizeText(raw);
    } catch {
      return "";
    }
  };

  return {
    /**
     * Build a read-only context block for Observe/Autonomous dispatch.
     * Returns empty string when unavailable.
     *
     * @param {object} params
     * @param {string} params.project
     * @param {string} params.mode
     * @param {string} [params.resolvedProjectPath]
     * @param {boolean} [params.hasStableContext]
     * @returns {string}
     */
    getContextBlock({ project, mode, resolvedProjectPath = "", hasStableContext = false }) {
      const normalizedMode = `${mode || ""}`.toLowerCase();
      if (normalizedMode !== "observe" && normalizedMode !== "autonomous") return "";
      if (hasStableContext && !forceWhenStableExists) return "";
      if (!ensureCommandAvailable()) return "";

      const root = resolveProjectRoot({ project, resolvedProjectPath });
      if (!root) {
        const key = `${project || "unknown"}`;
        const now = Date.now();
        const last = rootMissLogAt.get(key) || 0;
        if (now - last > ROOT_MISS_LOG_COOLDOWN_MS) {
          rootMissLogAt.set(key, now);
          log?.debug?.(`clawgate: project_view root unresolved (project=${key})`);
        }
        return "";
      }

      const files = resolveProjectFiles(project);
      if (!files.length) return "";
      const cacheKey = `${project}::${root}::${files.join(",")}`;
      const now = Date.now();
      const cached = cache.get(cacheKey);
      if (cached && cached.expiresAt > now) return cached.block;

      let remaining = maxTotalChars;
      const sections = [];
      for (const file of files) {
        if (remaining < 120) break;
        const content = readOneFile(root, file);
        if (!content) continue;
        const capped = capText(content, Math.min(maxFileChars, remaining - 40));
        const section = `### ${file}\n${capped}`;
        sections.push(section);
        remaining -= section.length + 2;
      }

      if (!sections.length) return "";

      const block = [
        `[Project View Snapshot]`,
        `source=${activeCommand} root=${root}`,
        sections.join("\n\n"),
      ].join("\n");

      cache.set(cacheKey, { block, expiresAt: now + ttlMs });
      return block;
    },
  };
}

/**
 * context-reader.js — Read project files and build context strings for AI.
 *
 * Two-layer context strategy (Stable + Dynamic):
 *   - Stable: CLAUDE.md + dynamically detected referenced files + CC knowledge
 *     Sent only on first dispatch or when content hash changes.
 *   - Dynamic: git state + recent work logs
 *     Sent every time (lightweight envelope ~1.5K chars).
 *
 * Respects privacy: never reads .env, .local/, credentials, or source code.
 */

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { join, basename } from "node:path";

const MAX_STABLE_CHARS = 12000;
const MAX_ENVELOPE_CHARS = 1500;
const MAX_FILE_CHARS = 4000;
const MAX_LOG_CHARS = 300;
const CONTEXT_FILES = ["CLAUDE.md", "AGENTS.md", "README.md"];
const LOG_DIR = "docs/log/claude";

/** Pattern matching absolute/relative image file paths. */
const IMAGE_PATH_PATTERN =
  /(?:\/[\w./~-]+\.(?:png|jpe?g|gif|webp|bmp|tiff?|heic|heif))/gi;

/**
 * Replace image file paths with safe placeholders so that downstream
 * consumers (e.g. OpenClaw detectImageReferences) won't try to embed them.
 * @param {string} text
 * @returns {string}
 */
function sanitizeImagePaths(text) {
  return text.replace(IMAGE_PATH_PATTERN, (match) => {
    const name = match.split("/").pop();
    return `<${name}>`;
  });
}

/**
 * Safely read a file, returning empty string on failure.
 * @param {string} filePath
 * @param {number} [maxChars]
 * @returns {string}
 */
function safeRead(filePath, maxChars = MAX_FILE_CHARS) {
  try {
    if (!existsSync(filePath)) return "";
    const content = readFileSync(filePath, "utf-8");
    if (content.length <= maxChars) return content;
    return content.slice(0, maxChars) + "\n... (truncated)";
  } catch {
    return "";
  }
}

/**
 * Get git branch and recent commits for a project.
 * @param {string} projectPath
 * @returns {string}
 */
function getGitInfo(projectPath) {
  try {
    const branch = execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: projectPath,
      encoding: "utf-8",
      timeout: 3000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();

    const log = execSync("git log --oneline -3 --no-decorate", {
      cwd: projectPath,
      encoding: "utf-8",
      timeout: 3000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();

    let result = `Branch: ${branch}`;
    if (log) {
      result += `\nRecent commits:\n${log}`;
    }
    return result;
  } catch {
    return "";
  }
}

/**
 * Get the latest work log entries from docs/log/claude/.
 * @param {string} projectPath
 * @param {number} [count=2]
 * @returns {string}
 */
function getRecentLogs(projectPath, count = 2) {
  const logDir = join(projectPath, LOG_DIR);
  try {
    if (!existsSync(logDir)) return "";
    const files = readdirSync(logDir)
      .filter((f) => f.endsWith(".md"))
      .sort()
      .reverse()
      .slice(0, count);

    if (!files.length) return "";

    const entries = files.map((f) => {
      const content = safeRead(join(logDir, f), MAX_LOG_CHARS);
      return `${f}\n${content}`;
    });

    return entries.join("\n\n");
  } catch {
    return "";
  }
}

/**
 * Extract referenced file paths from CLAUDE.md content.
 *
 * Detects three patterns:
 *   1. Key Files section: "- `SPEC.md` — description"
 *   2. Read-first directives: "read `SPEC.md` first"
 *   3. Persistence directives: "go in `docs/testing.md`"
 *
 * @param {string} claudeMdContent
 * @returns {string[]} — deduplicated file paths
 */
export function extractReferencedFiles(claudeMdContent) {
  if (!claudeMdContent) return [];

  const found = new Set();

  // Pattern 1: Key Files section bullet points
  //   - `SPEC.md` — Full technical specification
  const keyFilePattern = /^-\s+`([^`]+)`\s+[—-]/gm;
  let match;
  while ((match = keyFilePattern.exec(claudeMdContent)) !== null) {
    found.add(match[1]);
  }

  // Pattern 2: "read X first" directives
  //   always read `SPEC.md` first
  const readFirstPattern = /read\s+`([^`]+)`/gi;
  while ((match = readFirstPattern.exec(claudeMdContent)) !== null) {
    found.add(match[1]);
  }

  // Pattern 3: "go in / stored in" persistence directives
  //   all go in `docs/testing.md`
  const persistPattern = /(?:go|stored?)\s+in\s+`([^`]+)`/gi;
  while ((match = persistPattern.exec(claudeMdContent)) !== null) {
    found.add(match[1]);
  }

  // Filter out non-file references and CLAUDE.md itself
  const result = [...found].filter((f) => {
    if (f === "CLAUDE.md") return false;
    // Must look like a file path (has extension or known dir prefix)
    return /\.\w+$/.test(f) || f.startsWith("docs/") || f.startsWith("plans/");
  });

  return result;
}

/**
 * Smart truncation: prioritize headings and important lines.
 * Keeps the structure of markdown documents while fitting within budget.
 *
 * @param {string} content
 * @param {number} maxChars
 * @returns {string}
 */
export function smartTruncate(content, maxChars) {
  if (content.length <= maxChars) return content;

  const lines = content.split("\n");
  const result = [];
  let chars = 0;

  for (const line of lines) {
    const isHeading = /^#{1,4}\s/.test(line);
    const isImportant = /\*\*IMPORTANT\*\*|CRITICAL|NEVER|MUST/i.test(line);

    // Headings and important lines are always included
    if (isHeading || isImportant) {
      result.push(line);
      chars += line.length + 1;
      continue;
    }

    // Include other lines within budget
    if (chars + line.length < maxChars * 0.9) {
      result.push(line);
      chars += line.length + 1;
    }

    if (chars >= maxChars) {
      result.push("... (truncated)");
      break;
    }
  }

  return result.join("\n");
}

/**
 * Build the stable context layer.
 * Contains CLAUDE.md + dynamically detected referenced files.
 * Intended to be sent only once (or when hash changes).
 *
 * @param {string} projectPath — absolute path to the project root
 * @returns {{ context: string, hash: string }}
 */
export function buildStableContext(projectPath) {
  const projectName = basename(projectPath);
  const parts = [];
  let totalChars = 0;

  // Header
  const header = `[Project: ${projectName}]\nPath: ${projectPath}`;
  parts.push(header);
  totalChars += header.length;

  // Read CLAUDE.md first (primary source for reference detection)
  const claudeMdPath = join(projectPath, "CLAUDE.md");
  const claudeMdRaw = safeRead(claudeMdPath, MAX_FILE_CHARS);

  // Detect referenced files from CLAUDE.md
  const referencedFiles = extractReferencedFiles(claudeMdRaw);

  // Build priority file list: CLAUDE.md first, then referenced, then fallback
  const allFiles = ["CLAUDE.md"];
  for (const ref of referencedFiles) {
    if (!allFiles.includes(ref)) allFiles.push(ref);
  }
  // Add standard files that weren't already detected
  for (const std of CONTEXT_FILES) {
    if (!allFiles.includes(std)) allFiles.push(std);
  }

  // Read files within budget
  for (const file of allFiles) {
    if (totalChars >= MAX_STABLE_CHARS) break;
    const filePath = join(projectPath, file);
    const budget = Math.min(MAX_FILE_CHARS, MAX_STABLE_CHARS - totalChars);
    if (budget < 100) break;

    let content;
    if (file === "CLAUDE.md") {
      // Already read
      content = claudeMdRaw;
    } else {
      content = safeRead(filePath, MAX_FILE_CHARS);
    }
    if (!content) continue;

    // Apply smart truncation if over budget
    const truncated = content.length > budget ? smartTruncate(content, budget) : content;
    const section = `### ${file}\n${truncated}`;
    parts.push(section);
    totalChars += section.length;
  }

  const context = sanitizeImagePaths(parts.join("\n\n"));
  const hash = simpleHash(context);
  return { context, hash };
}

/**
 * Build the dynamic envelope layer.
 * Contains git state + recent work logs. Sent every time (~1.5K chars).
 *
 * @param {string} projectPath — absolute path to the project root
 * @returns {{ envelope: string }}
 */
export function buildDynamicEnvelope(projectPath) {
  const parts = [];
  let totalChars = 0;

  // Git info
  const gitInfo = getGitInfo(projectPath);
  if (gitInfo) {
    parts.push(gitInfo);
    totalChars += gitInfo.length;
  }

  // Recent work logs
  if (totalChars < MAX_ENVELOPE_CHARS) {
    const logs = getRecentLogs(projectPath);
    if (logs) {
      const budget = MAX_ENVELOPE_CHARS - totalChars;
      const logSection =
        logs.length <= budget
          ? `Recent work logs:\n${logs}`
          : `Recent work logs:\n${logs.slice(0, budget)}\n... (truncated)`;
      parts.push(logSection);
    }
  }

  const envelope = parts.join("\n\n");
  return { envelope };
}

/**
 * Build full project context string for tmux completion events.
 * Backward-compatible wrapper that combines stable + dynamic layers.
 *
 * @param {string} projectPath — absolute path to the project root
 * @returns {{ context: string, hash: string }}
 */
export function buildProjectContext(projectPath) {
  const { context: stable, hash } = buildStableContext(projectPath);
  const { envelope } = buildDynamicEnvelope(projectPath);

  const parts = [stable];
  if (envelope) parts.push(envelope);

  const context = parts.join("\n\n");
  return { context, hash };
}

/**
 * Build a compact project roster for LINE messages.
 * One line per project, ~200 chars total.
 *
 * @param {{ name: string, path: string, mode: string, status?: string, pendingQuestion?: string }[]} projects
 * @returns {string}
 */
export function buildProjectRoster(projects) {
  if (!projects.length) return "";

  const lines = projects.map((p) => {
    const branch = getProjectBranch(p.path);
    const status = p.status || "unknown";
    const asking = p.pendingQuestion
      ? ` [ASKING: ${p.pendingQuestion.slice(0, 30)}]`
      : "";
    return `- ${p.name} (${branch}) [${p.mode}] ${status}${asking}`;
  });

  return lines.join("\n");
}

/**
 * Get just the branch name for a project (fast path for roster).
 * @param {string} projectPath
 * @returns {string}
 */
function getProjectBranch(projectPath) {
  try {
    return execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: projectPath,
      encoding: "utf-8",
      timeout: 2000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "?";
  }
}

/**
 * Simple string hash for cache invalidation.
 * @param {string} str
 * @returns {string}
 */
function simpleHash(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash + str.charCodeAt(i)) | 0;
  }
  return hash.toString(36);
}

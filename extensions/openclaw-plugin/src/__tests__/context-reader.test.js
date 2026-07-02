/**
 * Characterization tests for context-reader.js.
 *
 * Pure helpers (extractReferencedFiles / smartTruncate) are tested directly —
 * importing them also confirms the exports are legitimate. The fs-backed
 * builders are exercised against throwaway tmp fixtures created under
 * os.tmpdir() (outside the repo, so not a git worktree), which makes their
 * git-dependent branches resolve deterministically ("" envelope / "?" branch)
 * without mocking.
 */

import { describe, it, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";

import {
  extractReferencedFiles,
  smartTruncate,
  buildStableContext,
  buildDynamicEnvelope,
  buildProjectContext,
  buildProjectRoster,
} from "../context-reader.js";

// ── tmp fixture management ───────────────────────────────────────
const createdDirs = [];
function makeTmpProject(files = {}) {
  const dir = mkdtempSync(join(tmpdir(), "ctx-reader-test-"));
  createdDirs.push(dir);
  for (const [name, content] of Object.entries(files)) {
    writeFileSync(join(dir, name), content, "utf-8");
  }
  return dir;
}
afterEach(() => {
  while (createdDirs.length) {
    const dir = createdDirs.pop();
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
});

describe("extractReferencedFiles", () => {
  it("returns [] for empty or falsy content", () => {
    assert.deepEqual(extractReferencedFiles(""), []);
    assert.deepEqual(extractReferencedFiles(null), []);
  });

  it("detects all three patterns and applies the file/dir filter", () => {
    const md = [
      "- `SPEC.md` — Full spec",
      "- `notafile` — no extension so dropped",
      "always read `NOTES.md` first",
      "all go in `docs/testing.md`",
      "data stored in `plans/roadmap`",
      "read `CLAUDE.md` here",
    ].join("\n");
    assert.deepEqual(extractReferencedFiles(md), [
      "SPEC.md",
      "NOTES.md",
      "docs/testing.md",
      "plans/roadmap",
    ]);
  });

  it("excludes CLAUDE.md itself", () => {
    assert.deepEqual(extractReferencedFiles("read `CLAUDE.md` first"), []);
  });

  it("deduplicates a file referenced by multiple patterns", () => {
    const md = "- `SPEC.md` — spec\nalways read `SPEC.md` first";
    assert.deepEqual(extractReferencedFiles(md), ["SPEC.md"]);
  });

  it("ignores a Key Files bullet without an em-dash/hyphen separator", () => {
    assert.deepEqual(extractReferencedFiles("- `SPEC.md` just a description"), []);
  });
});

describe("smartTruncate", () => {
  it("returns content unchanged when within budget", () => {
    assert.equal(smartTruncate("abc\ndef", 100), "abc\ndef");
  });

  it("always keeps headings and IMPORTANT/MUST lines while dropping over-budget normals", () => {
    const content = [
      "## Heading A",
      "filler line one two three",
      "MUST keep this line",
      "another filler line here",
      "### Heading B",
    ].join("\n");
    assert.equal(
      smartTruncate(content, 20),
      "## Heading A\nMUST keep this line\n... (truncated)"
    );
  });

  it("keeps normal lines that fit and drops over-budget ones without a truncation marker", () => {
    const content = "short one\nshort two\n" + "x".repeat(60);
    assert.equal(smartTruncate(content, 50), "short one\nshort two");
  });
});

describe("buildStableContext", () => {
  it("builds a header + CLAUDE.md section with a string hash", () => {
    const dir = makeTmpProject({ "CLAUDE.md": "# Test Project\nSome content here" });
    const { context, hash } = buildStableContext(dir);
    assert.match(context, new RegExp(`\\[Project: ${basename(dir)}\\]`));
    assert.match(context, /### CLAUDE\.md/);
    assert.match(context, /Some content here/);
    assert.equal(typeof hash, "string");
    assert.ok(hash.length > 0);
  });

  it("includes a referenced file section detected from CLAUDE.md", () => {
    const dir = makeTmpProject({
      "CLAUDE.md": "- `SPEC.md` — the spec",
      "SPEC.md": "spec body content",
    });
    const { context } = buildStableContext(dir);
    assert.match(context, /### SPEC\.md/);
    assert.match(context, /spec body content/);
  });

  it("returns just the header when no context files exist", () => {
    const dir = makeTmpProject();
    const { context } = buildStableContext(dir);
    assert.match(context, new RegExp(`\\[Project: ${basename(dir)}\\]`));
    assert.doesNotMatch(context, /### /);
  });

  it("sanitizes image paths into <name> placeholders", () => {
    const dir = makeTmpProject({ "CLAUDE.md": "see /some/dir/pic.png for details" });
    const { context } = buildStableContext(dir);
    assert.match(context, /<pic\.png>/);
    assert.doesNotMatch(context, /\/some\/dir\/pic\.png/);
  });
});

describe("buildDynamicEnvelope", () => {
  it("returns an empty envelope for a non-git project with no logs", () => {
    const dir = makeTmpProject();
    assert.deepEqual(buildDynamicEnvelope(dir), { envelope: "" });
  });
});

describe("buildProjectContext", () => {
  it("combines stable context with the (empty) dynamic envelope on a non-git fixture", () => {
    const dir = makeTmpProject({ "CLAUDE.md": "# Combined\nbody text" });
    const combined = buildProjectContext(dir);
    const stable = buildStableContext(dir);
    // envelope is "" for a non-git dir, so context === stable context
    assert.equal(combined.context, stable.context);
    assert.equal(combined.hash, stable.hash);
    assert.match(combined.context, /### CLAUDE\.md/);
  });
});

describe("buildProjectRoster", () => {
  it("returns empty string for no projects", () => {
    assert.equal(buildProjectRoster([]), "");
  });

  it("formats a single project line with '?' branch on a non-git path", () => {
    const dir = makeTmpProject();
    assert.equal(
      buildProjectRoster([{ name: "proj-a", path: dir, mode: "observe" }]),
      "- proj-a (?) [observe] unknown"
    );
  });

  it("appends a truncated ASKING marker for a pending question", () => {
    const dir = makeTmpProject();
    assert.equal(
      buildProjectRoster([
        { name: "proj-b", path: dir, mode: "autonomous", status: "running", pendingQuestion: "Deploy now?" },
      ]),
      "- proj-b (?) [autonomous] running [ASKING: Deploy now?]"
    );
  });

  it("appends the last 5 lines of progressText as indented latest output", () => {
    const dir = makeTmpProject();
    assert.equal(
      buildProjectRoster([{ name: "proj-c", path: dir, mode: "auto", progressText: "a\nb\nc" }]),
      "- proj-c (?) [auto] unknown\n  Latest output:\n  a\n  b\n  c"
    );
  });
});

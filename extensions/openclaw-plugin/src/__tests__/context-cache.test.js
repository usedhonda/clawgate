/**
 * Characterization tests for context-cache.js.
 *
 * context-reader.js and client.js are stubbed via mock.module so the tests
 * exercise context-cache's OWN caching / dedup / filtering logic against
 * deterministic builders, not the real fs-backed readers. Pure helpers
 * (capText / filterPaneNoise / deduplicateTrailAgainst) need no stubs.
 */

import { describe, it, beforeEach, afterEach, mock } from "node:test";
import assert from "node:assert/strict";

// Records every buildProjectContext call so tests can distinguish a cache hit
// (no new call) from a rebuild (new call). Reset per relevant test.
let buildContextCalls = [];

mock.module("../context-reader.js", {
  namedExports: {
    buildProjectContext: (path) => {
      buildContextCalls.push(path);
      return { context: `ctx#${buildContextCalls.length}:${path}`, hash: `h#${buildContextCalls.length}` };
    },
    buildStableContext: (path) => ({ context: `stable:${path}`, hash: `stablehash:${path}` }),
    buildDynamicEnvelope: (path) => ({ envelope: `env:${path}` }),
    buildProjectRoster: (projects) => `ROSTER[${projects.map((p) => p.name).join("|")}]`,
  },
});

mock.module("../client.js", {
  namedExports: {
    resolveTmuxWorkingDir: (target) => (target ? `/wd/${target}` : null),
  },
});

const cc = await import("../context-cache.js");

describe("capText", () => {
  it("returns text unchanged when shorter than maxChars", () => {
    assert.equal(cc.capText("abc", 5), "abc");
  });

  it("returns text unchanged when exactly maxChars", () => {
    assert.equal(cc.capText("abc", 3), "abc");
  });

  it("returns falsy input as-is (empty string / null)", () => {
    assert.equal(cc.capText("", 5), "");
    assert.equal(cc.capText(null, 5), null);
  });

  it("tail strategy (default) keeps the end with a truncation prefix", () => {
    assert.equal(cc.capText("abcdef", 3), "...(truncated)\ndef");
  });

  it("head strategy keeps the start with a truncation suffix", () => {
    assert.equal(cc.capText("abcdef", 3, "head"), "abc\n...(truncated)");
  });
});

describe("filterPaneNoise", () => {
  it("returns empty string for empty input", () => {
    assert.equal(cc.filterPaneNoise(""), "");
  });

  it("strips separators, short lines, blanks, and token-stat noise while keeping meaningful lines", () => {
    const input = [
      "Editing config file",
      "─────────",
      "xyz",
      "12.5k tokens ·",
      "81.2K/160K",
      "Running tests",
    ].join("\n");
    assert.equal(cc.filterPaneNoise(input), "Editing config file\nRunning tests");
  });

  it("trims surrounding whitespace from the result", () => {
    assert.equal(cc.filterPaneNoise("\n\nMeaningful work here\n\n"), "Meaningful work here");
  });
});

describe("deduplicateTrailAgainst", () => {
  it("returns the trail unchanged when trail or reference is falsy", () => {
    assert.equal(cc.deduplicateTrailAgainst("", "ref"), "");
    assert.equal(cc.deduplicateTrailAgainst("trail", ""), "trail");
  });

  it("drops entries whose lines mostly appear in the reference, keeps the rest", () => {
    const trail = "line A\nline B\n---\nunique C\nunique D";
    const reference = "line A\nline B";
    assert.equal(cc.deduplicateTrailAgainst(trail, reference), "unique C\nunique D");
  });

  it("returns null when every entry is deduplicated away", () => {
    assert.equal(cc.deduplicateTrailAgainst("line A\nline B", "line A\nline B"), null);
  });

  it("drops an entry at exactly 50% overlap (threshold is strictly < 0.5)", () => {
    assert.equal(cc.deduplicateTrailAgainst("match1\nnomatch1", "match1"), null);
  });
});

describe("getProjectContext 5min TTL cache", () => {
  const realDateNow = Date.now;
  let mockNow = realDateNow();

  beforeEach(() => {
    buildContextCalls = [];
    mockNow = realDateNow();
    Date.now = () => mockNow;
  });
  afterEach(() => {
    Date.now = realDateNow;
  });

  it("returns null when the path cannot be resolved (no cache, no tmux target)", () => {
    assert.equal(cc.getProjectContext("ttl-unresolvable"), null);
    assert.equal(buildContextCalls.length, 0);
  });

  it("builds and caches on first call, then serves the cache within the TTL", () => {
    const first = cc.getProjectContext("ttl-proj-1", "pane-1");
    assert.equal(buildContextCalls.length, 1);
    mockNow += 5 * 60 * 1000 - 1; // still within 5min
    const second = cc.getProjectContext("ttl-proj-1", "pane-1");
    assert.equal(second, first);
    assert.equal(buildContextCalls.length, 1); // no rebuild
  });

  it("rebuilds after the TTL elapses", () => {
    cc.getProjectContext("ttl-proj-2", "pane-2");
    assert.equal(buildContextCalls.length, 1);
    mockNow += 5 * 60 * 1000 + 1; // past 5min
    cc.getProjectContext("ttl-proj-2", "pane-2");
    assert.equal(buildContextCalls.length, 2); // rebuilt
  });

  it("invalidateProject forces a rebuild on the next call", () => {
    cc.getProjectContext("ttl-proj-3", "pane-3");
    assert.equal(buildContextCalls.length, 1);
    cc.invalidateProject("ttl-proj-3");
    cc.getProjectContext("ttl-proj-3", "pane-3");
    assert.equal(buildContextCalls.length, 2);
  });
});

describe("resolveProjectPath", () => {
  it("returns null with no cached path and no tmux target", () => {
    assert.equal(cc.resolveProjectPath("rp-none"), null);
  });

  it("resolves via tmux, caches, and returns the cached path without a target next time", () => {
    assert.equal(cc.resolveProjectPath("rp-proj", "rp-pane"), "/wd/rp-pane");
    assert.equal(cc.resolveProjectPath("rp-proj"), "/wd/rp-pane");
  });
});

describe("stable context dedup (getStableContext / markContextSent)", () => {
  it("returns null when the path cannot be resolved", () => {
    assert.equal(cc.getStableContext("sc-none"), null);
  });

  it("reports isNew=true until the hash is marked sent, then isNew=false", () => {
    const first = cc.getStableContext("sc-proj", "sc-pane");
    assert.equal(first.isNew, true);
    assert.equal(first.hash, "stablehash:/wd/sc-pane");
    cc.markContextSent("sc-proj", first.hash);
    const second = cc.getStableContext("sc-proj", "sc-pane");
    assert.equal(second.isNew, false);
  });
});

describe("getDynamicEnvelope", () => {
  it("returns null when the path cannot be resolved", () => {
    assert.equal(cc.getDynamicEnvelope("de-none"), null);
  });

  it("returns the freshly built envelope when the path resolves", () => {
    assert.deepEqual(cc.getDynamicEnvelope("de-proj", "de-pane"), { envelope: "env:/wd/de-pane" });
  });
});

describe("progress snapshots", () => {
  it("set then get returns text and a timestamp; unknown is null", () => {
    assert.equal(cc.getProgressSnapshot("ps-unknown"), null);
    cc.setProgressSnapshot("ps-proj", "building the thing");
    const snap = cc.getProgressSnapshot("ps-proj");
    assert.equal(snap.text, "building the thing");
    assert.equal(typeof snap.timestamp, "number");
  });
});

describe("task goals", () => {
  it("set trims and stores; get returns it; unknown is null; clear removes", () => {
    assert.equal(cc.getTaskGoal("tg-unknown"), null);
    cc.setTaskGoal("tg-proj", "  ship the feature  ");
    assert.equal(cc.getTaskGoal("tg-proj"), "ship the feature");
    cc.clearTaskGoal("tg-proj");
    assert.equal(cc.getTaskGoal("tg-proj"), null);
  });

  it("ignores empty or whitespace-only goals", () => {
    cc.setTaskGoal("tg-empty", "   ");
    assert.equal(cc.getTaskGoal("tg-empty"), null);
  });
});

describe("progress trail (appendProgressTrail / getProgressTrail / clearProgressTrail)", () => {
  it("skips noise-only appends and returns null for an empty trail", () => {
    cc.appendProgressTrail("pt-noise", "───────\n12.5k tokens ·");
    assert.equal(cc.getProgressTrail("pt-noise"), null);
  });

  it("stores meaningful content, dedups a consecutive identical entry, and joins entries with ---", () => {
    cc.appendProgressTrail("pt-proj", "Implementing feature X");
    assert.equal(cc.getProgressTrail("pt-proj"), "Implementing feature X");
    cc.appendProgressTrail("pt-proj", "Implementing feature X"); // identical -> deduped
    assert.equal(cc.getProgressTrail("pt-proj"), "Implementing feature X");
    cc.appendProgressTrail("pt-proj", "Testing feature X");
    assert.equal(cc.getProgressTrail("pt-proj"), "Implementing feature X\n---\nTesting feature X");
  });

  it("clearProgressTrail empties the trail", () => {
    cc.appendProgressTrail("pt-clear", "Some real work happening");
    cc.clearProgressTrail("pt-clear");
    assert.equal(cc.getProgressTrail("pt-clear"), null);
  });
});

describe("getProjectRoster", () => {
  it("includes non-ignore projects and excludes ignore-mode projects", () => {
    cc.registerProjectPath("roster-inc", "/abs/roster-inc");
    cc.registerProjectPath("roster-ign", "/abs/roster-ign");
    const modes = new Map([
      ["roster-inc", "autonomous"],
      ["roster-ign", "ignore"],
    ]);
    const roster = cc.getProjectRoster(modes);
    assert.match(roster, /roster-inc/);
    assert.doesNotMatch(roster, /roster-ign/);
  });
});

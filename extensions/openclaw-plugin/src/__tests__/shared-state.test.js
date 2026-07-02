import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

import {
  setActiveProject,
  getActiveProject,
  clearActiveProject,
  setSessionMode,
  getSessionMode,
  registerDevLaneEnqueue,
  enqueueDevLaneText,
  rememberTprojOrigin,
  lookupTprojOrigin,
} from "../shared-state.js";

// The three TTL maps read time via Date.now() directly, so we drive expiry by
// swapping Date.now with a controllable clock rather than sleeping. The maps are
// module singletons shared across tests, so every test uses unique keys to avoid
// cross-test contamination.
const realDateNow = Date.now;
let mockNow = realDateNow();

function advance(ms) {
  mockNow += ms;
}

describe("activeDispatchProjects (setActiveProject/getActiveProject/clearActiveProject)", () => {
  beforeEach(() => {
    mockNow = realDateNow();
    Date.now = () => mockNow;
  });
  afterEach(() => {
    Date.now = realDateNow;
  });

  it("set then get returns the stored project and sessionType", () => {
    setActiveProject("adp-conv-1", "clawgate", "codex");
    assert.deepEqual(getActiveProject("adp-conv-1"), { project: "clawgate", sessionType: "codex" });
  });

  it("defaults sessionType to claude_code when omitted", () => {
    setActiveProject("adp-conv-2", "tproj");
    assert.deepEqual(getActiveProject("adp-conv-2"), { project: "tproj", sessionType: "claude_code" });
  });

  it("ignores set when conversation or project is falsy", () => {
    setActiveProject("", "clawgate");
    setActiveProject("adp-conv-3", "");
    assert.deepEqual(getActiveProject("adp-conv-3"), { project: "", sessionType: "claude_code" });
  });

  it("get on an unknown conversation returns the empty default", () => {
    assert.deepEqual(getActiveProject("adp-never-set"), { project: "", sessionType: "claude_code" });
  });

  it("get with a falsy conversation returns the empty default", () => {
    assert.deepEqual(getActiveProject(""), { project: "", sessionType: "claude_code" });
  });

  it("expires an entry older than 60s on get and evicts it", () => {
    setActiveProject("adp-conv-4", "clawgate", "codex");
    advance(60_001);
    assert.deepEqual(getActiveProject("adp-conv-4"), { project: "", sessionType: "claude_code" });
    // entry was deleted, so rolling the clock back still yields the default
    mockNow = realDateNow();
    assert.deepEqual(getActiveProject("adp-conv-4"), { project: "", sessionType: "claude_code" });
  });

  it("keeps an entry at exactly 60s (boundary is strictly greater-than)", () => {
    setActiveProject("adp-conv-5", "clawgate", "codex");
    advance(60_000);
    assert.deepEqual(getActiveProject("adp-conv-5"), { project: "clawgate", sessionType: "codex" });
  });

  it("cleanup on set evicts other stale entries older than 60s", () => {
    setActiveProject("adp-stale", "old-project", "codex");
    advance(60_001);
    // a fresh set triggers the inline cleanup loop that drops adp-stale
    setActiveProject("adp-fresh", "new-project", "codex");
    assert.deepEqual(getActiveProject("adp-fresh"), { project: "new-project", sessionType: "codex" });
    assert.deepEqual(getActiveProject("adp-stale"), { project: "", sessionType: "claude_code" });
  });

  it("clearActiveProject removes a live entry", () => {
    setActiveProject("adp-conv-6", "clawgate", "codex");
    clearActiveProject("adp-conv-6");
    assert.deepEqual(getActiveProject("adp-conv-6"), { project: "", sessionType: "claude_code" });
  });

  it("clearActiveProject is a no-op for a falsy conversation", () => {
    setActiveProject("adp-conv-7", "clawgate", "codex");
    clearActiveProject("");
    assert.deepEqual(getActiveProject("adp-conv-7"), { project: "clawgate", sessionType: "codex" });
  });
});

describe("sessionModeByProject (setSessionMode/getSessionMode)", () => {
  it("set then get returns the mode", () => {
    setSessionMode("sm-proj-1", "autonomous");
    assert.equal(getSessionMode("sm-proj-1"), "autonomous");
  });

  it("normalizes mode to trimmed lowercase", () => {
    setSessionMode("sm-proj-2", "  Autonomous  ");
    assert.equal(getSessionMode("sm-proj-2"), "autonomous");
  });

  it("trims the project key on both set and get", () => {
    setSessionMode("  sm-proj-3  ", "observe");
    assert.equal(getSessionMode("sm-proj-3"), "observe");
    assert.equal(getSessionMode("  sm-proj-3  "), "observe");
  });

  it("stores 'ignore' when mode is falsy", () => {
    setSessionMode("sm-proj-4", "");
    assert.equal(getSessionMode("sm-proj-4"), "ignore");
  });

  it("stores 'ignore' when mode is whitespace only", () => {
    setSessionMode("sm-proj-5", "   ");
    assert.equal(getSessionMode("sm-proj-5"), "ignore");
  });

  it("ignores set when project is empty or whitespace", () => {
    setSessionMode("", "autonomous");
    setSessionMode("   ", "autonomous");
    assert.equal(getSessionMode(""), "ignore");
    assert.equal(getSessionMode("   "), "ignore");
  });

  it("returns 'ignore' for an unknown project", () => {
    assert.equal(getSessionMode("sm-never-set"), "ignore");
  });

  it("returns 'ignore' for a falsy project on get", () => {
    assert.equal(getSessionMode(""), "ignore");
    assert.equal(getSessionMode(null), "ignore");
  });
});

describe("dev-lane enqueue (registerDevLaneEnqueue/enqueueDevLaneText)", () => {
  afterEach(() => {
    // reset the module-level enqueue impl so tests stay isolated
    registerDevLaneEnqueue(null);
  });

  it("returns false when no enqueue impl is registered", () => {
    registerDevLaneEnqueue(null);
    assert.equal(enqueueDevLaneText({ project: "p", text: "t", mode: "autonomous" }), false);
  });

  it("forwards a trimmed, normalized entry to the registered impl and returns true", () => {
    const calls = [];
    registerDevLaneEnqueue((entry) => {
      calls.push(entry);
      return true;
    });
    const result = enqueueDevLaneText({ project: "  proj  ", text: "hello", mode: "autonomous", traceId: "trace-1" });
    assert.equal(result, true);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], { project: "proj", text: "hello", mode: "autonomous", traceId: "trace-1" });
  });

  it("defaults mode and traceId to empty strings when omitted", () => {
    const calls = [];
    registerDevLaneEnqueue((entry) => {
      calls.push(entry);
      return true;
    });
    enqueueDevLaneText({ project: "proj", text: "hello" });
    assert.deepEqual(calls[0], { project: "proj", text: "hello", mode: "", traceId: "" });
  });

  it("returns true unless the impl explicitly returns false", () => {
    registerDevLaneEnqueue(() => undefined);
    assert.equal(enqueueDevLaneText({ project: "proj", text: "t" }), true);
  });

  it("returns false when the impl returns false", () => {
    registerDevLaneEnqueue(() => false);
    assert.equal(enqueueDevLaneText({ project: "proj", text: "t" }), false);
  });

  it("returns false when project or text is empty after trim", () => {
    const calls = [];
    registerDevLaneEnqueue((entry) => {
      calls.push(entry);
      return true;
    });
    assert.equal(enqueueDevLaneText({ project: "   ", text: "t" }), false);
    assert.equal(enqueueDevLaneText({ project: "proj", text: "" }), false);
    assert.equal(calls.length, 0);
  });

  it("returns false when the impl throws", () => {
    registerDevLaneEnqueue(() => {
      throw new Error("boom");
    });
    assert.equal(enqueueDevLaneText({ project: "proj", text: "t" }), false);
  });

  it("registering a non-function resets the impl to disabled", () => {
    registerDevLaneEnqueue(() => true);
    registerDevLaneEnqueue("not-a-function");
    assert.equal(enqueueDevLaneText({ project: "proj", text: "t" }), false);
  });

  it("returns false when called with no arguments", () => {
    registerDevLaneEnqueue(() => true);
    assert.equal(enqueueDevLaneText(), false);
  });
});

describe("tprojOriginStore (rememberTprojOrigin/lookupTprojOrigin)", () => {
  beforeEach(() => {
    mockNow = realDateNow();
    Date.now = () => mockNow;
  });
  afterEach(() => {
    Date.now = realDateNow;
  });

  const origin = {
    returnUrl: "ws://example-host:9999/federation",
    sender: "clawgate.cc",
    workspace: "tproj-workspace",
    mode: "autonomous",
  };

  it("remember then lookup returns the stored origin fields", () => {
    rememberTprojOrigin("to-conv-1", origin);
    const rec = lookupTprojOrigin("to-conv-1");
    assert.equal(rec.returnUrl, origin.returnUrl);
    assert.equal(rec.sender, origin.sender);
    assert.equal(rec.workspace, origin.workspace);
    assert.equal(rec.mode, "autonomous");
  });

  it("defaults mode to 'autonomous' when omitted", () => {
    rememberTprojOrigin("to-conv-2", { returnUrl: origin.returnUrl, sender: origin.sender, workspace: origin.workspace });
    assert.equal(lookupTprojOrigin("to-conv-2").mode, "autonomous");
  });

  it("preserves a non-default mode", () => {
    rememberTprojOrigin("to-conv-3", { ...origin, mode: "observe" });
    assert.equal(lookupTprojOrigin("to-conv-3").mode, "observe");
  });

  it("ignores remember when any required field is missing", () => {
    rememberTprojOrigin("", origin);
    rememberTprojOrigin("to-conv-4", { ...origin, returnUrl: "" });
    rememberTprojOrigin("to-conv-5", { ...origin, sender: "" });
    rememberTprojOrigin("to-conv-6", { ...origin, workspace: "" });
    assert.equal(lookupTprojOrigin("to-conv-4"), null);
    assert.equal(lookupTprojOrigin("to-conv-5"), null);
    assert.equal(lookupTprojOrigin("to-conv-6"), null);
  });

  it("lookup on an unknown conversation returns null", () => {
    assert.equal(lookupTprojOrigin("to-never-set"), null);
  });

  it("lookup with a falsy conversation returns null", () => {
    assert.equal(lookupTprojOrigin(""), null);
  });

  it("expires an entry older than the 10min TTL and evicts it", () => {
    rememberTprojOrigin("to-conv-7", origin);
    advance(10 * 60 * 1000 + 1);
    assert.equal(lookupTprojOrigin("to-conv-7"), null);
    // eviction happened: rolling the clock back still yields null
    mockNow = realDateNow();
    assert.equal(lookupTprojOrigin("to-conv-7"), null);
  });

  it("keeps an entry at exactly the 10min boundary (strictly greater-than)", () => {
    rememberTprojOrigin("to-conv-8", origin);
    advance(10 * 60 * 1000);
    assert.equal(lookupTprojOrigin("to-conv-8").returnUrl, origin.returnUrl);
  });
});

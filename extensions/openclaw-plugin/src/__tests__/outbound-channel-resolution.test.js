import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { resolveOutboundChannel } from "../gateway.js";

const header = { sender: "clawgate.cc", project: "clawgate", workspace: "tproj-workspace", reply: "session" };

describe("resolveOutboundChannel fail-safe routing", () => {
  it("routes every parsed tproj header to telegram when failsafe is enabled", () => {
    for (const ingressAdapter of ["line", "telegram", "tmux", "unknown", undefined]) {
      assert.equal(
        resolveOutboundChannel({ ingressAdapter, tprojHeader: header, failsafe: true }),
        "telegram",
        `ingressAdapter=${ingressAdapter}`
      );
    }
  });

  it("preserves legacy line-before-header priority when failsafe is disabled", () => {
    assert.equal(resolveOutboundChannel({ ingressAdapter: "line", tprojHeader: header, failsafe: false }), "line");

    for (const ingressAdapter of ["telegram", "tmux", "unknown", undefined]) {
      assert.equal(
        resolveOutboundChannel({ ingressAdapter, tprojHeader: header, failsafe: false }),
        "telegram",
        `ingressAdapter=${ingressAdapter}`
      );
    }
  });

  it("keeps explicit LINE ingress on LINE when no tproj header is present", () => {
    assert.equal(resolveOutboundChannel({ ingressAdapter: "line", tprojHeader: null, failsafe: true }), "line");
    assert.equal(resolveOutboundChannel({ ingressAdapter: "line", tprojHeader: undefined }), "line");
  });

  it("keeps explicit Telegram ingress on Telegram", () => {
    assert.equal(resolveOutboundChannel({ ingressAdapter: "telegram", tprojHeader: null, failsafe: true }), "telegram");
    assert.equal(resolveOutboundChannel({ ingressAdapter: "telegram", tprojHeader: header, failsafe: false }), "telegram");
  });

  it("routes dev-lane and unknown ingress to telegram instead of LINE", () => {
    for (const ingressAdapter of ["tmux", "direct", "gate", "unknown", "", undefined, null]) {
      assert.equal(
        resolveOutboundChannel({ ingressAdapter, tprojHeader: null, failsafe: true }),
        "telegram",
        `ingressAdapter=${ingressAdapter}`
      );
    }
  });

  it("routes development modes to telegram", () => {
    for (const mode of ["observe", "autonomous", "auto"]) {
      assert.equal(resolveOutboundChannel({ mode, failsafe: true }), "telegram", `mode=${mode}`);
      assert.equal(resolveOutboundChannel({ mode, failsafe: false }), "telegram", `mode=${mode}`);
    }
  });

  it("defaults empty input to telegram", () => {
    assert.equal(resolveOutboundChannel(), "telegram");
    assert.equal(resolveOutboundChannel({}), "telegram");
  });
});

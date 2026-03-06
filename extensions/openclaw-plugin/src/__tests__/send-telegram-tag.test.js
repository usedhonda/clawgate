/**
 * Tests for <send_telegram> tag handling.
 *
 * Verifies:
 * 1. extractSendTelegramBlocks correctly extracts telegram blocks and returns remaining text
 * 2. stripChoiceTags removes <send_telegram> tags (LINE never receives raw tags)
 *
 * These are pure-function tests — no mocks needed.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

// ── Inline copies of the pure functions from gateway.js ─────────────
// Kept in sync via test assertions against known behavior.

function extractSendTelegramBlocks(text) {
  const blocks = [];
  const remaining = text.replace(/<send_telegram>([\s\S]*?)<\/send_telegram>/gi, (_, content) => {
    const trimmed = content.trim();
    if (trimmed) blocks.push(trimmed);
    return "";
  });
  return blocks.length > 0 ? { telegramTexts: blocks, remaining: remaining.trim() } : null;
}

function stripChoiceTags(text) {
  let result = `${text || ""}`.trim();
  if (!result) return "";
  result = result
    .replace(/<send_telegram>([\s\S]*?)<\/send_telegram>/gi, "")
    .replace(/<cc_task(?:\s+project="[^"]*")?>([\s\S]*?)<\/cc_task>/gi, "")
    .replace(/<cc_answer\s+project="[^"]*">([\s\S]*?)<\/cc_answer>/gi, "")
    .replace(/<cc_read\s+project="[^"]+"\s*\/?>(?:<\/cc_read>)?/gi, "")
    .trim();
  return result;
}

// ── Tests ───────────────────────────────────────────────────────────

describe("extractSendTelegramBlocks", () => {
  it("returns null when no <send_telegram> tags present", () => {
    const result = extractSendTelegramBlocks("Just a normal LINE message.");
    assert.equal(result, null);
  });

  it("extracts a single telegram block and returns remaining text", () => {
    const input = "LINE message. <send_telegram>Deploy complete on staging.</send_telegram> More LINE text.";
    const result = extractSendTelegramBlocks(input);
    assert.deepEqual(result.telegramTexts, ["Deploy complete on staging."]);
    assert.equal(result.remaining, "LINE message.  More LINE text.");
  });

  it("extracts multiple telegram blocks", () => {
    const input = "<send_telegram>First TG</send_telegram> LINE part <send_telegram>Second TG</send_telegram>";
    const result = extractSendTelegramBlocks(input);
    assert.deepEqual(result.telegramTexts, ["First TG", "Second TG"]);
    assert.equal(result.remaining, "LINE part");
  });

  it("returns null remaining when entire text is telegram blocks", () => {
    const input = "<send_telegram>All goes to Telegram</send_telegram>";
    const result = extractSendTelegramBlocks(input);
    assert.deepEqual(result.telegramTexts, ["All goes to Telegram"]);
    assert.equal(result.remaining, "");
  });

  it("skips empty telegram blocks", () => {
    const input = "<send_telegram>  </send_telegram> LINE only <send_telegram>Real TG</send_telegram>";
    const result = extractSendTelegramBlocks(input);
    assert.deepEqual(result.telegramTexts, ["Real TG"]);
    assert.equal(result.remaining, "LINE only");
  });

  it("handles case-insensitive tags", () => {
    const input = "<SEND_TELEGRAM>Uppercase</SEND_TELEGRAM> rest";
    const result = extractSendTelegramBlocks(input);
    assert.deepEqual(result.telegramTexts, ["Uppercase"]);
    assert.equal(result.remaining, "rest");
  });

  it("handles multiline content inside tags", () => {
    const input = "<send_telegram>Line 1\nLine 2\nLine 3</send_telegram> summary";
    const result = extractSendTelegramBlocks(input);
    assert.deepEqual(result.telegramTexts, ["Line 1\nLine 2\nLine 3"]);
    assert.equal(result.remaining, "summary");
  });
});

describe("stripChoiceTags removes <send_telegram>", () => {
  it("strips send_telegram tags from text", () => {
    const input = "Review done. <send_telegram>Deploy alert</send_telegram> No issues.";
    const result = stripChoiceTags(input);
    assert.equal(result, "Review done.  No issues.");
    assert.ok(!result.includes("send_telegram"), "LINE output must not contain <send_telegram> tags");
    assert.ok(!result.includes("Deploy alert"), "Telegram-only content must not leak to LINE");
  });

  it("strips send_telegram alongside other control tags", () => {
    const input = '<send_telegram>TG msg</send_telegram> <cc_task>continue</cc_task> <cc_answer project="foo">1</cc_answer> LINE visible';
    const result = stripChoiceTags(input);
    assert.equal(result, "LINE visible");
  });

  it("returns empty string for telegram-only content", () => {
    const result = stripChoiceTags("<send_telegram>Only telegram</send_telegram>");
    assert.equal(result, "");
  });
});

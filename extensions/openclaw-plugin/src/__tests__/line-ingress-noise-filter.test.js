import { describe, it } from "node:test";
import assert from "node:assert/strict";

let _filterDisplayName = "Alice Smith";

function isUiChromeLine(line) {
  const s = line.trim();
  if (!s) return true;
  if (/^既読$/.test(s)) return true;
  if (/^未読$/.test(s)) return true;
  if (/^ここから未読メッセージ$/.test(s)) return true;
  if (/^LINE$/.test(s)) return true;
  if (/友だち検索|おすすめ公式アカウント|トークを始めよう|検索結果がありません/u.test(s)) return true;
  if (/^(友だち|グループ|公式アカウント|知り合いかも)\s*\d*$/u.test(s)) return true;
  if (_filterDisplayName && s.startsWith(_filterDisplayName) && (s.length === _filterDisplayName.length || /\W/.test(s[_filterDisplayName.length]))) return true;
  if (/^(午前|午後)\s*\d{1,2}:\d{2}$/.test(s)) return true;
  if (/^\d{1,2}:\d{2}$/.test(s)) return true;
  if (/^\d+$/.test(s)) return true;
  if (/^[\p{P}\p{S}\s_]+$/u.test(s)) return true;
  return false;
}

function normalizeCompactLine(text) {
  return `${text || ""}`.replace(/\s+/g, " ").trim();
}

function looksLikeShortOcrGarbage(text) {
  const s = normalizeCompactLine(text);
  if (!s) return true;
  if (isUiChromeLine(s)) return true;
  if (s.length <= 12 && !/[。！？!?]/u.test(s)) return true;
  return false;
}

function stripDisplayNameNoisePrefix(line) {
  let s = normalizeCompactLine(line);
  const displayName = normalizeCompactLine(_filterDisplayName);
  if (!s || !displayName) return s;

  let stripped = false;
  while (s.startsWith(displayName)) {
    stripped = true;
    s = normalizeCompactLine(s.slice(displayName.length));
    s = s
      .replace(/^[0-9０-９]+\s*/u, "")
      .replace(/^[A-Za-z]\s*/u, "")
      .replace(/^[ァ-ヶー]{1,3}\s*/u, "");
    s = normalizeCompactLine(s);
    if (!s) return "";
  }

  if (!stripped) return normalizeCompactLine(line);
  if (looksLikeShortOcrGarbage(s)) return "";
  return s;
}

function mergeWrappedLines(lines) {
  if (!Array.isArray(lines) || lines.length <= 1) return lines || [];
  const merged = [];
  const shouldAppend = (prev, next) => {
    if (!prev || !next) return false;
    if (isUiChromeLine(prev) || isUiChromeLine(next)) return false;
    if (/[。！？!?]$/.test(prev)) return false;
    if (prev.length <= 36 || next.length <= 20) return true;
    if (!/[、。！？!?]$/.test(prev) && /^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}A-Za-z0-9]/u.test(next)) {
      return true;
    }
    return false;
  };
  for (const line of lines) {
    if (merged.length === 0) {
      merged.push(line);
      continue;
    }
    const prev = merged[merged.length - 1];
    if (shouldAppend(prev, line)) {
      merged[merged.length - 1] = `${prev}${line}`;
    } else {
      merged.push(line);
    }
  }
  return merged;
}

function normalizeInboundText(rawText, source) {
  const text = (rawText || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  if (!text) return "";
  if (source === "notification_banner") return text;

  let lines = text
    .split("\n")
    .map((l) => stripDisplayNameNoisePrefix(l))
    .filter((l) => l.length > 0)
    .filter((l) => !isUiChromeLine(l));

  lines = mergeWrappedLines(lines);

  if (lines.length === 0) {
    const rawLines = text
      .split("\n")
      .map((l) => l.replace(/\s+/g, " ").trim())
      .filter((l) => l.length > 0);
    if (rawLines.length > 0) {
      const fallbackLine = stripDisplayNameNoisePrefix(rawLines[rawLines.length - 1]);
      if (fallbackLine && !isUiChromeLine(fallbackLine)) {
        lines = [fallbackLine];
      }
    }
  }

  const result = lines.join("\n").trim();
  if (result && looksLikeShortOcrGarbage(result)) return "";
  return result;
}

describe("LINE inbound noise filtering", () => {
  it("drops owner-name header garbage instead of resurrecting it via raw fallback", () => {
    assert.equal(normalizeInboundText("Alice Smith 1ロ", "hybrid_fusion"), "");
    assert.equal(normalizeInboundText("Alice Smith 4 ロ今日今日", "hybrid_fusion"), "");
  });

  it("strips owner-name OCR prefix but keeps meaningful tail text", () => {
    assert.equal(
      normalizeInboundText("Alice Smith 4送信テスト。よめてる？", "hybrid_fusion"),
      "送信テスト。よめてる？"
    );
  });

  it("drops obvious LINE chrome keyword blocks", () => {
    assert.equal(
      normalizeInboundText("友だち検索\nおすすめ公式アカウント\nトークを始めよう！", "hybrid_fusion"),
      ""
    );
  });

  it("drops friends-list tab labels", () => {
    assert.equal(normalizeInboundText("友だち", "hybrid_fusion"), "");
    assert.equal(normalizeInboundText("友だち 1", "hybrid_fusion"), "");
    assert.equal(normalizeInboundText("グループ", "hybrid_fusion"), "");
    assert.equal(normalizeInboundText("公式アカウント", "hybrid_fusion"), "");
    assert.equal(normalizeInboundText("知り合いかも", "hybrid_fusion"), "");
    assert.equal(normalizeInboundText("知り合いかも 3", "hybrid_fusion"), "");
  });

  it("drops search-box leftover fragments via final garbage check", () => {
    assert.equal(normalizeInboundText("Alice Smith 4 G", "hybrid_fusion"), "");
  });

  it("keeps real messages intact", () => {
    assert.equal(
      normalizeInboundText("こんにちは！お元気ですか？", "hybrid_fusion"),
      "こんにちは！お元気ですか？"
    );
  });
});

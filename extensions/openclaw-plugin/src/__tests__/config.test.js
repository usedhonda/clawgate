import assert from "node:assert/strict";
import test from "node:test";
import { listAccountIds, defaultAccountId, resolveAccount } from "../config.js";

test("account discovery ignores null, arrays, and scalar channel metadata", () => {
  const cfg = { channels: { clawgate: {
    broken: null, allowFrom: ["fixture"], enabled: true, label: "fixture",
    second: { telegramChatId: "fixture" }, default: { telegramChatId: "fixture" },
  } } };
  assert.deepEqual(listAccountIds(cfg), ["second", "default"]);
  assert.equal(defaultAccountId(cfg), "default");
  assert.deepEqual(listAccountIds({ channels: { clawgate: [] } }), []);
  assert.equal(resolveAccount(cfg).accountId, "default");
  assert.equal(resolveAccount(cfg, "second").accountId, "second");
  delete cfg.channels.clawgate.default;
  assert.equal(resolveAccount(cfg).accountId, "second");
});

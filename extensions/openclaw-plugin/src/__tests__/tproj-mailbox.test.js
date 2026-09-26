import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadMailboxConfig,
  runMailboxBatch,
  createTprojMailboxService,
  createTprojMessageTool,
} from "../tproj-mailbox.js";

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "tproj-mailbox-"));
  const configPath = join(dir, "msg-service.json");
  const journalPath = join(dir, "journal.json");
  writeFileSync(configPath, JSON.stringify({ socket: "/tmp/fake.sock", service_token: "secret", address: "gate", journal_path: journalPath }));
  return { dir, configPath, journalPath };
}

describe("tproj mailbox adapter", () => {
  it("is opt-in and rejects incomplete configuration", () => {
    const dir = mkdtempSync(join(tmpdir(), "tproj-mailbox-config-"));
    assert.equal(loadMailboxConfig(join(dir, "missing.json")), null);
    writeFileSync(join(dir, "bad.json"), JSON.stringify({ socket: "/tmp/x", address: "gate" }));
    assert.equal(loadMailboxConfig(join(dir, "bad.json")), null);
  });

  it("claims bounded messages, dispatches through runtime, and replies by immutable ID", async () => {
    const { configPath, journalPath } = fixture();
    const config = loadMailboxConfig(configPath);
    const calls = [];
    const runtime = {
      config: { current: () => ({ agents: { entries: { main: {} } } }) },
      channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async ({ ctx, dispatcherOptions }) => {
        assert.equal(ctx._tprojMailbox.messageId, "m-1");
        assert.match(ctx.SessionKey, /proj\.cc%7Cthread-1/);
        await dispatcherOptions.deliver({ text: "reply" });
      } } },
    };
    const rpc = async (_socket, request) => {
      calls.push(request);
      if (request.op === "service_claim") return { ok: true, result: { messages: [{ message_id: "m-1", thread_id: "thread-1", body: "hello", sender_endpoint: "proj.cc", recipient_endpoint: "gate" }] } };
      return { ok: true, result: {} };
    };
    const result = await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    assert.deepEqual(result, { claimed: 1, dispatched: 1, skipped: 0 });
    assert.equal(calls[0].op, "service_claim");
    assert.equal(calls[1].op, "service_reply");
    assert.equal(calls[1].message_id, "m-1");
    assert.equal(calls[2].op, "service_receipt");
    assert.equal(calls[2].state, "presented");
    const journal = JSON.parse(readFileSync(journalPath, "utf8"));
    assert.equal(journal.messages["m-1"].status, "presented");
    const skipped = await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    assert.deepEqual(skipped, { claimed: 1, dispatched: 0, skipped: 1 });
  });

  it("does not blindly rerun a dispatch left uncertain after a crash", async () => {
    const { configPath } = fixture();
    const config = loadMailboxConfig(configPath);
    const runtime = { channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async () => { throw new Error("crash"); } } } };
    const calls = [];
    const rpc = async (_socket, request) => { calls.push(request); return request.op === "service_claim" ? { messages: [{ message_id: "m-2", thread_id: "t-2", body: "x", sender_endpoint: "a.cc" }] } : { ok: true }; };
    await assert.rejects(() => runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } }), /crash/);
    const second = await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    assert.deepEqual(second, { claimed: 1, dispatched: 0, skipped: 1 });
    assert.ok(calls.some((call) => call.op === "service_receipt" && call.state === "uncertain"));
  });

  it("registers as a background service without starting when config is absent", () => {
    let ticks = 0;
    const service = createTprojMailboxService({ configPath: "/definitely/missing/msg-service.json", runtime: {} });
    service.start({ logger: { warn() { ticks++; } } });
    assert.equal(ticks, 0);
  });

  it("fails closed on a corrupt journal instead of replaying claims", async () => {
    const { configPath, journalPath } = fixture();
    writeFileSync(journalPath, "not-json");
    const config = loadMailboxConfig(configPath);
    await assert.rejects(() => runMailboxBatch({ config, runtime: {}, rpc: async () => ({ messages: [] }) }), /journal unreadable/);
  });

  it("registers the send tool only for configured main agent and sends through service_send", async () => {
    const calls = [];
    const tool = createTprojMessageTool({
      ctx: { agentId: "main", config: { agents: { defaults: { systemAgent: { agentId: "main" } } } } },
      send: async (value) => { calls.push(value); return { state: "queued", message_id: "m-7" }; },
    });
    assert.ok(tool);
    const result = await tool.execute("call-1", { target: "proj.cc", body: "hello" });
    assert.deepEqual(calls, [{ target: "proj.cc", body: "hello" }]);
    assert.equal(result.details.message_id, "m-7");
    assert.equal(createTprojMessageTool({ ctx: { agentId: "worker", config: {} } }), null);
  });
});

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadMailboxConfig,
  runMailboxBatch,
  sendMailboxMessage,
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
        assert.match(ctx.GroupSystemPrompt, /plain text/);
        assert.match(ctx.SessionKey, /proj\.cc%7Cthread-1/);
        await dispatcherOptions.deliver({ text: "reply" }, { kind: "final" });
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

  it("merges concurrent send-tool journal entries and only presents a final payload", async () => {
    const { configPath, journalPath } = fixture();
    const config = loadMailboxConfig(configPath);
    let dispatchCalls = 0;
    const runtime = {
      config: { current: () => ({ agents: { entries: { main: {} } } }) },
      channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async ({ dispatcherOptions }) => {
        dispatchCalls++;
        await dispatcherOptions.deliver({ text: "⚠️ Message failed", isError: true }, { kind: "final" });
      } } },
    };
    const rpc = async (_socket, request) => {
      if (request.op === "service_claim") return { messages: [{ message_id: "m-race", thread_id: "t", body: "hello", sender_endpoint: "proj.cc" }] };
      if (request.op === "service_send") return { message_id: "outbound-1", state: "queued" };
      return { message_id: "unexpected" };
    };
    const batch = runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await sendMailboxMessage({ config, target: "tproj.cdx", body: "concurrent", rpc });
    await batch;
    assert.equal(dispatchCalls, 1);
    const journal = JSON.parse(readFileSync(journalPath, "utf8"));
    assert.equal(journal.messages["m-race"].status, "uncertain");
    assert.equal(journal.outbound[Object.keys(journal.outbound).find((id) => journal.outbound[id].op === "service_send")].status, "accepted");
  });

  it("presents an inbound turn when an accepted service_send consumed it without a final callback", async () => {
    const { configPath, journalPath } = fixture();
    const config = loadMailboxConfig(configPath);
    const calls = [];
    const rpc = async (_socket, request) => {
      calls.push(request);
      if (request.op === "service_claim") return { messages: [{ message_id: "m-tool", thread_id: "t-tool", body: "hello", sender_endpoint: "artist.cc" }] };
      if (request.op === "service_send") return { message_id: "outbound-tool", state: "accepted" };
      return {};
    };
    const runtime = {
      config: { current: () => ({ agents: { entries: { main: {} } } }) },
      channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async ({ ctx }) => {
        const tool = createTprojMessageTool({
          ctx,
          send: (value) => sendMailboxMessage({ ...value, config, rpc }),
        });
        await tool.execute("call-tool", { target: "artist.cdx", body: "accepted outbound" });
      } } },
    };
    const result = await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    assert.deepEqual(result, { claimed: 1, dispatched: 1, skipped: 0 });
    assert.equal(calls.filter((call) => call.op === "service_reply").length, 0);
    const receipt = calls.find((call) => call.op === "service_receipt");
    assert.equal(receipt.state, "presented");
    assert.equal(receipt.evidence.bound_tool_send_accepted, true);
    const journal = JSON.parse(readFileSync(journalPath, "utf8"));
    const outbound = journal.outbound[Object.keys(journal.outbound).find((id) => journal.outbound[id].op === "service_send")];
    assert.equal(outbound.status, "accepted");
    assert.equal(outbound.inbound_message_id, "m-tool");
    assert.equal(journal.messages["m-tool"].status, "presented");
  });

  it("accepts only an unblocked deliberate silent terminal as no-reply completion evidence", async () => {
    const { configPath, journalPath } = fixture();
    const config = loadMailboxConfig(configPath);
    let mode = "silent";
    const receipts = [];
    const rpc = async (_socket, request) => {
      if (request.op === "service_claim") return { messages: [{ message_id: `m-${mode}`, body: "hello", sender_endpoint: "artist.cc" }] };
      if (request.op === "service_receipt") receipts.push(request);
      return {};
    };
    const runtime = {
      config: { current: () => ({ agents: { entries: { main: {} } } }) },
      channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async () => mode === "silent"
        ? { deliberateSilentTerminalReply: true }
        : { deliberateSilentTerminalReply: true, deferredToActiveRun: "followup" } } },
    };
    await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    assert.equal(receipts[0].state, "presented");
    mode = "deferred";
    await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    assert.equal(receipts[1].state, "uncertain");
    const journal = JSON.parse(readFileSync(journalPath, "utf8"));
    assert.equal(journal.messages["m-silent"].status, "presented");
    assert.equal(journal.messages["m-deferred"].status, "uncertain");
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

  it("supports explicit reply-to sends without changing new-message routing", async () => {
    const calls = [];
    const tool = createTprojMessageTool({
      ctx: { agentId: "main", config: { agents: { defaults: { systemAgent: { agentId: "main" } } } } },
      send: async (value) => { calls.push(value); return { state: "queued", message_id: "reply-1" }; },
    });
    await tool.execute("call-2", { reply_to: "m-1", body: "reply" });
    assert.deepEqual(calls, [{ target: "", body: "reply", replyTo: "m-1" }]);
  });

  it("uses an accepted explicit reply as presentation proof and suppresses an automatic duplicate", async () => {
    const { configPath, journalPath } = fixture();
    const config = loadMailboxConfig(configPath);
    const calls = [];
    const rpc = async (_socket, request) => {
      calls.push(request);
      if (request.op === "service_claim") return { messages: [{ message_id: "m-explicit", body: "hello", sender_endpoint: "proj.cc" }] };
      if (request.op === "service_reply") return { message_id: "reply-explicit" };
      return {};
    };
    await sendMailboxMessage({ config, replyTo: "m-explicit", body: "explicit", rpc });
    const runtime = {
      config: { current: () => ({ agents: { entries: { main: {} } } }) },
      channel: { reply: { dispatchReplyWithBufferedBlockDispatcher: async ({ dispatcherOptions }) => {
        await dispatcherOptions.deliver({ text: "automatic duplicate" }, { kind: "final" });
      } } },
    };
    await runMailboxBatch({ config, runtime, rpc, logger: { warn() {}, error() {} } });
    const journal = JSON.parse(readFileSync(journalPath, "utf8"));
    assert.equal(journal.messages["m-explicit"].status, "presented");
    assert.equal(calls.filter((call) => call.op === "service_reply").length, 1);
  });

  it("reuses a pending reply submission after an unknown RPC outcome", async () => {
    const { configPath, journalPath } = fixture();
    const config = loadMailboxConfig(configPath);
    const requests = [];
    let attempt = 0;
    const rpc = async (_socket, request) => {
      requests.push(request);
      if (request.op !== "service_reply") return {};
      attempt++;
      if (attempt === 1) throw new Error("connection lost after submit");
      return { message_id: "reply-retried" };
    };
    await assert.rejects(() => sendMailboxMessage({ config, replyTo: "m-retry", body: "reply", rpc }), /connection lost/);
    await sendMailboxMessage({ config, replyTo: "m-retry", body: "reply", rpc });
    assert.equal(requests[0].submission_id, requests[1].submission_id);
    const journal = JSON.parse(readFileSync(journalPath, "utf8"));
    assert.equal(Object.keys(journal.outbound).length, 1);
  });
});

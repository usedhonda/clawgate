/**
 * Opt-in unified tproj mailbox participant for OpenClaw main.
 *
 * This adapter deliberately does not use the ClawGate channel or LINE route.
 * The host agent owns identity and delivery; this process only claims bounded
 * envelopes and dispatches them through the supported plugin reply runtime.
 */
import net from "node:net";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, openSync, fsyncSync, closeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

const DEFAULT_CONFIG_PATH = join(homedir(), ".config", "tproj", "msg-service.json");
const DEFAULT_JOURNAL_PATH = join(homedir(), ".openclaw", "state", "tproj-mailbox-journal.json");
const DEFAULT_BATCH_SIZE = 8;
const DEFAULT_POLL_MS = 1000;
const RPC_TIMEOUT_MS = 10_000;

function unwrapRpcResponse(response) {
  if (response && response.ok === false) {
    const error = response.error || {};
    throw new Error(`tproj mailbox RPC ${error.code || "failed"}: ${error.message || "unknown error"}`);
  }
  return response && response.ok === true && Object.prototype.hasOwnProperty.call(response, "result")
    ? response.result : response;
}

let _runtime = null;
export function setTprojMailboxRuntime(runtime) { _runtime = runtime; }

export function loadMailboxConfig(configPath = DEFAULT_CONFIG_PATH) {
  if (!existsSync(configPath)) return null;
  let value;
  try { value = JSON.parse(readFileSync(configPath, "utf8")); } catch { return null; }
  if (!value || typeof value !== "object") return null;
  const socket = typeof value.socket === "string" ? value.socket.trim() : "";
  const serviceToken = typeof value.service_token === "string" ? value.service_token : "";
  const address = typeof value.address === "string" ? value.address.trim() : "";
  if (!socket || !serviceToken || !address) return null;
  return {
    socket,
    serviceToken,
    address,
    batchSize: Number.isInteger(value.batch_size) && value.batch_size > 0 ? Math.min(value.batch_size, 32) : DEFAULT_BATCH_SIZE,
    pollMs: Number.isInteger(value.poll_ms) && value.poll_ms >= 100 ? Math.min(value.poll_ms, 30_000) : DEFAULT_POLL_MS,
    journalPath: typeof value.journal_path === "string" && value.journal_path.trim() ? value.journal_path : DEFAULT_JOURNAL_PATH,
  };
}

function readJournal(path) {
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed && typeof parsed === "object" && parsed.messages && typeof parsed.messages === "object"
      ? parsed : { version: 1, messages: {} };
  } catch (error) {
    if (!existsSync(path)) return { version: 1, messages: {}, outbound: {} };
    throw new Error(`tproj mailbox journal unreadable: ${error.message}`);
  }
}

function writeJournal(path, journal) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.${randomUUID()}.tmp`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(journal)}\n`);
    fsyncSync(fd);
  } finally { closeSync(fd); }
  renameSync(tmp, path);
  const dirFd = openSync(dirname(path), "r");
  try { fsyncSync(dirFd); } finally { closeSync(dirFd); }
}

function rpcRequest(socketPath, request, timeoutMs = RPC_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let data = "";
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      error ? reject(error) : resolve(value);
    };
    const timer = setTimeout(() => finish(new Error("tproj mailbox RPC timeout")), timeoutMs);
    socket.once("error", (error) => { clearTimeout(timer); finish(error); });
    socket.on("data", (chunk) => {
      data += chunk.toString("utf8");
      const newline = data.indexOf("\n");
      if (newline < 0) return;
      clearTimeout(timer);
      try { finish(null, JSON.parse(data.slice(0, newline))); }
      catch (error) { finish(new Error(`invalid tproj mailbox RPC response: ${error.message}`)); }
    });
    socket.once("connect", () => socket.write(`${JSON.stringify(request)}\n`));
  });
}

function endpointKey(message) {
  return `${message.sender_endpoint || "unknown"}|${message.thread_id || message.message_id}`;
}

function buildMailboxContext(message, accountId = "tproj-mailbox", agentId = "main") {
  const sender = String(message.sender_endpoint || "unknown");
  const thread = String(message.thread_id || message.message_id);
  const contextKey = encodeURIComponent(`${sender}|${thread}`);
  const body = String(message.body || "");
  return {
    Body: body,
    RawBody: body,
    CommandBody: body,
    BodyForAgent: body,
    From: `tproj:${sender}`,
    To: `tproj:${accountId}`,
    SessionKey: `agent:${agentId}:tproj:${contextKey}`,
    AccountId: accountId,
    ChatType: "direct",
    Provider: "tproj",
    Surface: "tproj",
    ConversationLabel: thread,
    SenderName: sender,
    SenderId: sender,
    MessageSid: String(message.message_id),
    Timestamp: Date.now(),
    OriginatingChannel: "tproj",
    OriginatingTo: sender,
    _ingressAdapter: "tproj-mailbox",
    _tprojMailbox: {
      messageId: String(message.message_id),
      threadId: thread,
      senderEndpoint: sender,
      recipientEndpoint: String(message.recipient_endpoint || "gate"),
    },
  };
}

async function dispatchEnvelope(message, config, journal, logger, runtime = _runtime, rpc = rpcRequest) {
  if (!runtime?.channel?.reply?.dispatchReplyWithBufferedBlockDispatcher) {
    throw new Error("tproj mailbox: supported reply dispatcher unavailable");
  }
  const messageId = String(message.message_id);
  const origin = {
    message_id: messageId,
    thread_id: String(message.thread_id || messageId),
    sender_endpoint: String(message.sender_endpoint || "unknown"),
  };
  journal.messages[messageId] = {
    ...origin,
    key: endpointKey(message),
    status: "dispatching",
    claimed_at: new Date().toISOString(),
  };
  writeJournal(config.journalPath, journal);
  const cfg = typeof runtime.config?.current === "function" ? runtime.config.current() : runtime.config;
  const agentId = Object.keys(cfg?.agents?.entries || {})[0] || "main";
  const ctx = buildMailboxContext(message, "tproj-mailbox", agentId);
  const sendReply = async (body) => {
    const text = String(body || "").trim();
    if (!text) return;
    const submissionIds = journal.messages[messageId].reply_submission_ids || {};
    const submissionId = submissionIds[text] || randomUUID();
    submissionIds[text] = submissionId;
    journal.messages[messageId].reply_submission_ids = submissionIds;
    journal.outbound = journal.outbound || {};
    journal.outbound[submissionId] = { op: "service_reply", message_id: messageId, body: text, status: "pending", created_at: new Date().toISOString() };
    writeJournal(config.journalPath, journal);
    const replyResult = unwrapRpcResponse(await rpc(config.socket, {
      op: "service_reply",
      message_id: messageId,
      submission_id: submissionId,
      body: text,
      service_token: config.serviceToken,
    }));
    journal.outbound[submissionId].status = "accepted";
    journal.outbound[submissionId].result_message_id = replyResult?.message_id ? String(replyResult.message_id) : "";
    const replies = journal.messages[messageId].reply_ids || [];
    if (replyResult?.message_id) replies.push(String(replyResult.message_id));
    journal.messages[messageId].reply_ids = replies;
    writeJournal(config.journalPath, journal);
  };
  try {
    await runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
      ctx,
      cfg,
      dispatcherOptions: {
        deliver: async (payload) => sendReply(payload?.text ?? payload?.content ?? payload?.body ?? ""),
        humanDelay: { mode: "off" },
        onError: (error) => logger?.error?.(`tproj mailbox dispatch error: ${error}`),
      },
    });
    journal.messages[messageId].status = "presented";
    journal.messages[messageId].presented_at = new Date().toISOString();
    writeJournal(config.journalPath, journal);
    await rpc(config.socket, {
      op: "service_receipt",
      message_id: messageId,
      state: "presented",
      evidence: { adapter: "openclaw", session_key: ctx.SessionKey },
      service_token: config.serviceToken,
    });
  } catch (error) {
    journal.messages[messageId].status = "uncertain";
    journal.messages[messageId].error = String(error?.message || error);
    writeJournal(config.journalPath, journal);
    try {
      await rpc(config.socket, {
        op: "service_receipt",
        message_id: messageId,
        state: "uncertain",
        evidence: { adapter: "openclaw", error: String(error?.message || error) },
        service_token: config.serviceToken,
      });
    } catch (receiptError) { logger?.warn?.(`tproj mailbox uncertain receipt failed: ${receiptError}`); }
    throw error;
  }
}

export async function runMailboxBatch({ config, runtime = _runtime, logger = console, rpc = rpcRequest } = {}) {
  if (!config || !runtime) return { claimed: 0, dispatched: 0, skipped: 0 };
  const claim = unwrapRpcResponse(await rpc(config.socket, {
    op: "service_claim",
    address: config.address,
    service_token: config.serviceToken,
    limit: config.batchSize,
  }));
  const messages = Array.isArray(claim?.messages) ? claim.messages : [];
  const journal = readJournal(config.journalPath);
  journal.outbound = journal.outbound || {};
  let dispatched = 0; let skipped = 0;
  for (const message of messages) {
    const prior = journal.messages?.[String(message.message_id)];
    if (prior?.status === "dispatching") {
      prior.status = "uncertain";
      prior.error = "adapter restarted during dispatch";
      writeJournal(config.journalPath, journal);
      skipped++;
      continue;
    }
    if (prior?.status === "presented" || prior?.status === "uncertain") {
      skipped++;
      continue;
    }
    await dispatchEnvelope(message, config, journal, logger, runtime, rpc);
    dispatched++;
  }
  return { claimed: messages.length, dispatched, skipped };
}

/** Send a new agent message through the same authenticated service endpoint. */
export async function sendMailboxMessage({ target, body, submissionId, config = loadMailboxConfig(), rpc = rpcRequest } = {}) {
  if (!config) throw new Error("tproj mailbox is not configured");
  if (!String(target || "").trim() || !String(body || "").trim()) throw new Error("target and body are required");
  const journal = readJournal(config.journalPath);
  journal.outbound = journal.outbound || {};
  if (!submissionId) {
    submissionId = Object.entries(journal.outbound).find(([, entry]) =>
      entry?.op === "service_send" && entry.status === "pending" && entry.target === String(target) && entry.body === String(body)
    )?.[0] || randomUUID();
  }
  if (!journal.outbound[submissionId]) {
    journal.outbound[submissionId] = { op: "service_send", target: String(target), body: String(body), status: "pending", created_at: new Date().toISOString() };
    writeJournal(config.journalPath, journal);
  }
  return rpc(config.socket, {
    op: "service_send",
    target: String(target),
    body: String(body),
    submission_id: submissionId,
    service_token: config.serviceToken,
  }).then((response) => {
    const result = unwrapRpcResponse(response);
    const updated = readJournal(config.journalPath);
    updated.outbound = updated.outbound || {};
    if (updated.outbound[submissionId]) {
      updated.outbound[submissionId].status = "accepted";
      updated.outbound[submissionId].result_message_id = result?.message_id ? String(result.message_id) : "";
      writeJournal(config.journalPath, updated);
    }
    return result;
  });
}

export function createTprojMailboxService({ runtime = _runtime, configPath = DEFAULT_CONFIG_PATH, rpc = rpcRequest } = {}) {
  let stopped = false;
  let timer = null;
  let running = false;
  return {
    id: "tproj-mailbox",
    start(context = {}) {
      const config = loadMailboxConfig(configPath);
      if (!config) return;
      stopped = false;
      const tick = async () => {
        if (stopped || running) return;
        running = true;
        try { await runMailboxBatch({ config, runtime, logger: context.logger, rpc }); }
        catch (error) { context.logger?.warn?.(`tproj mailbox poll failed: ${error}`); }
        finally {
          running = false;
          if (!stopped) timer = setTimeout(tick, config.pollMs);
        }
      };
      void tick();
    },
    async stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
      timer = null;
    },
  };
}

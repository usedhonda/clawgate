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

function resolveMainAgentId(cfg) {
  const configured = cfg?.agents?.defaults?.systemAgent;
  if (typeof configured === "string" && configured.trim()) return configured.trim();
  if (configured && typeof configured.agentId === "string" && configured.agentId.trim()) return configured.agentId.trim();
  const entries = cfg?.agents?.entries;
  if (Array.isArray(entries) && typeof entries[0] === "string" && entries[0].trim()) return entries[0].trim();
  if (entries && typeof entries === "object") {
    const first = Object.keys(entries)[0];
    if (first) return first;
  }
  return "main";
}

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

// Always merge against the on-disk journal. Dispatch and send-tool callbacks
// can update it independently; writing a stale in-memory object would erase
// the other operation's outbound evidence.
function updateJournal(path, mutate) {
  const journal = readJournal(path);
  const result = mutate(journal);
  writeJournal(path, journal);
  return result;
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

function normalizedSessionKey(value) {
  return String(value || "").replace(/%[0-9a-f]{2}/gi, (escape) => escape.toLowerCase());
}

function buildMailboxContext(message, accountId = "tproj-mailbox", agentId = "main") {
  const sender = String(message.sender_endpoint || "unknown");
  const thread = String(message.thread_id || message.message_id);
  const contextKey = encodeURIComponent(`${sender}|${thread}`);
  const body = String(message.body || "");
  const routing = `[tproj mailbox adapter: inbound message_id=${String(message.message_id)} sender=${sender}] Reply to this turn by writing the final answer as plain text; it will be correlated to message_id=${String(message.message_id)}. Do not use generic message or session tools for this reply. If an explicit tool reply is needed, use tproj_message with reply_to=${String(message.message_id)}. For new outbound messages, use tproj_message with a project.cc or project.cdx target.`;
  return {
    Body: body,
    RawBody: body,
    CommandBody: body,
    BodyForAgent: `${routing}\n\n${body}`,
    From: `tproj:${sender}`,
    To: `tproj:${accountId}`,
    SessionKey: `agent:${agentId}:tproj:${contextKey}`,
    agentId,
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
    GroupSystemPrompt: routing,
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
  const cfg = typeof runtime.config?.current === "function" ? runtime.config.current() : runtime.config;
  const agentId = resolveMainAgentId(cfg);
  const ctx = buildMailboxContext(message, "tproj-mailbox", agentId);
  updateJournal(config.journalPath, (current) => {
    current.messages[messageId] = {
      ...current.messages[messageId],
      ...origin,
      key: endpointKey(message),
      session_key: ctx.SessionKey,
      status: "dispatching",
      claimed_at: new Date().toISOString(),
    };
  });
  const sendReply = async (body) => {
    const text = String(body || "").trim();
    if (!text) return;
    const submissionId = updateJournal(config.journalPath, (current) => {
      current.messages[messageId] = current.messages[messageId] || { ...origin };
      const submissionIds = current.messages[messageId].reply_submission_ids || {};
      const existingId = submissionIds[text];
      if (existingId) return existingId;
      const nextId = randomUUID();
      submissionIds[text] = nextId;
      current.messages[messageId].reply_submission_ids = submissionIds;
      current.outbound = current.outbound || {};
      current.outbound[nextId] = { op: "service_reply", message_id: messageId, body: text, status: "pending", created_at: new Date().toISOString() };
      return nextId;
    });
    const latest = readJournal(config.journalPath);
    if (latest.outbound?.[submissionId]?.status === "accepted") return;
    const replyResult = unwrapRpcResponse(await rpc(config.socket, {
      op: "service_reply",
      message_id: messageId,
      submission_id: submissionId,
      body: text,
      service_token: config.serviceToken,
    }));
    updateJournal(config.journalPath, (current) => {
      current.outbound = current.outbound || {};
      if (current.outbound[submissionId]) {
        current.outbound[submissionId].status = "accepted";
        current.outbound[submissionId].result_message_id = replyResult?.message_id ? String(replyResult.message_id) : "";
      }
      current.messages[messageId] = current.messages[messageId] || { ...origin };
      const replies = current.messages[messageId].reply_ids || [];
      if (replyResult?.message_id && !replies.includes(String(replyResult.message_id))) replies.push(String(replyResult.message_id));
      current.messages[messageId].reply_ids = replies;
    });
  };
  let finalReplyDelivered = false;
  const explicitReplyAccepted = () => {
    const current = readJournal(config.journalPath);
    return Object.values(current.outbound || {}).some((entry) => entry?.op === "service_reply" && entry.message_id === messageId && entry.status === "accepted");
  };
  const boundToolSendAccepted = () => {
    const current = readJournal(config.journalPath);
    return Object.values(current.outbound || {}).some((entry) =>
      entry?.op === "service_send" && entry.inbound_message_id === messageId && entry.status === "accepted"
    );
  };
  try {
    const dispatchResult = await runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
      ctx,
      cfg,
      dispatcherOptions: {
        deliver: async (payload, info) => {
          if (info?.kind !== "final" || explicitReplyAccepted() || boundToolSendAccepted()) return;
          if (payload?.isError || payload?.isReasoning || payload?.isCommentary || payload?.isCompactionNotice || payload?.isFallbackNotice || payload?.isStatusNotice) return;
          const text = payload?.text ?? payload?.content ?? payload?.body ?? "";
          if (!String(text).trim()) return;
          finalReplyDelivered = true;
          await sendReply(text);
        },
        humanDelay: { mode: "off" },
        onError: (error) => logger?.error?.(`tproj mailbox dispatch error: ${error}`),
      },
    });
    const explicitReply = explicitReplyAccepted();
    const toolSendAccepted = boundToolSendAccepted();
    const deliberateSilentTerminal = dispatchResult?.deliberateSilentTerminalReply === true
      && dispatchResult?.beforeAgentRunBlocked !== true
      && !dispatchResult?.deferredToActiveRun
      && dispatchResult?.sendPolicyDenied !== true;
    const presented = explicitReply || toolSendAccepted || deliberateSilentTerminal || (finalReplyDelivered && dispatchResult?.observedReplyDelivery !== false);
    updateJournal(config.journalPath, (current) => {
      current.messages[messageId] = current.messages[messageId] || { ...origin };
      current.messages[messageId].status = presented ? "presented" : "uncertain";
      if (presented) current.messages[messageId].presented_at = new Date().toISOString();
      else current.messages[messageId].error = "dispatcher completed without a final reply delivery";
    });
    await rpc(config.socket, {
      op: "service_receipt",
      message_id: messageId,
      state: presented ? "presented" : "uncertain",
      evidence: {
        adapter: "openclaw",
        session_key: ctx.SessionKey,
        final_reply_delivered: finalReplyDelivered,
        explicit_reply_accepted: explicitReply,
        bound_tool_send_accepted: toolSendAccepted,
        deliberate_silent_terminal: deliberateSilentTerminal,
      },
      service_token: config.serviceToken,
    });
  } catch (error) {
    updateJournal(config.journalPath, (current) => {
      current.messages[messageId] = current.messages[messageId] || { ...origin };
      current.messages[messageId].status = "uncertain";
      current.messages[messageId].error = String(error?.message || error);
    });
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
export async function sendMailboxMessage({ target, body, replyTo, submissionId, inboundMessageId, config = loadMailboxConfig(), rpc = rpcRequest } = {}) {
  if (!config) throw new Error("tproj mailbox is not configured");
  if ((!String(target || "").trim() && !String(replyTo || "").trim()) || !String(body || "").trim()) throw new Error("target or reply_to, and body are required");
  const operation = String(replyTo || "").trim() ? "service_reply" : "service_send";
  const targetValue = String(target || "").trim();
  const replyToValue = String(replyTo || "").trim();
  const journal = readJournal(config.journalPath);
  journal.outbound = journal.outbound || {};
  if (!submissionId) {
    submissionId = Object.entries(journal.outbound).find(([, entry]) =>
      entry?.op === operation && entry.status === "pending" && String(entry.target || "") === targetValue && entry.body === String(body) && (!replyToValue || entry.message_id === replyToValue) && (!inboundMessageId || entry.inbound_message_id === String(inboundMessageId))
    )?.[0] || randomUUID();
  }
  if (!journal.outbound[submissionId]) {
    updateJournal(config.journalPath, (current) => {
      current.outbound = current.outbound || {};
      if (!current.outbound[submissionId]) current.outbound[submissionId] = {
        op: operation,
        ...(targetValue ? { target: targetValue } : {}),
        ...(replyToValue ? { message_id: replyToValue } : {}),
        ...(inboundMessageId ? { inbound_message_id: String(inboundMessageId) } : {}),
        body: String(body),
        status: "pending",
        created_at: new Date().toISOString(),
      };
    });
  }
  const request = {
    op: operation,
    ...(targetValue ? { target: targetValue } : {}),
    ...(replyToValue ? { message_id: replyToValue } : {}),
    body: String(body),
    submission_id: submissionId,
    service_token: config.serviceToken,
  };
  return rpc(config.socket, request).then((response) => {
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

export function createTprojMessageTool({ ctx, send = sendMailboxMessage, journalPath = loadMailboxConfig()?.journalPath } = {}) {
  const cfg = ctx?.getRuntimeConfig?.() ?? ctx?.runtimeConfig ?? ctx?.config ?? {};
  const mainAgentId = resolveMainAgentId(cfg);
  if (!ctx?.agentId || ctx.agentId !== mainAgentId) return null;
  return {
    name: "tproj_message",
    label: "tproj message",
    description: "Send a unified tproj mailbox message to a participant.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        target: { type: "string", minLength: 1 },
        body: { type: "string", minLength: 1 },
        reply_to: { type: "string", minLength: 1 },
      },
      required: ["body"],
    },
    async execute(_toolCallId, params) {
      const target = String(params?.target || "").trim();
      const body = String(params?.body || "");
      const replyTo = String(params?.reply_to || "").trim();
      if ((!target && !replyTo) || !body) throw new Error("target or reply_to, and body are required");
      const matching = journalPath && ctx?.sessionKey
        ? Object.values(readJournal(journalPath).messages).filter((entry) =>
          entry?.status === "dispatching" && normalizedSessionKey(entry.session_key) === normalizedSessionKey(ctx.sessionKey))
        : [];
      const inboundMessageId = matching.length === 1 ? matching[0].message_id : "";
      const sendArgs = replyTo ? { target, body, replyTo } : { target, body };
      if (inboundMessageId && !replyTo) sendArgs.inboundMessageId = inboundMessageId;
      const result = await send(sendArgs);
      return {
        content: [{ type: "text", text: JSON.stringify({ state: result?.state || "accepted", message_id: result?.message_id || null }) }],
        details: { state: result?.state || "accepted", message_id: result?.message_id || null },
      };
    },
  };
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

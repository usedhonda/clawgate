import { it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { prepareBufferedLineReply } from "../gateway.js";
import {
  createLineReplyExpectation, observeLineReplyExpectation,
  confirmLineReplyExpectation, setLineReplyTtsRuntime,
} from "../line-reply-tts.js";

it("fingerprints the fixed rendered LINE companion text, not raw markdown or Telegram-only content", async () => {
  const raw = "  ## Result\r\n**Ready**  \r\n\r\n<send_telegram>Telegram-only detail</send_telegram>\r\nFinal 🚂  ";
  const rendered = "[demo.cc]\nResult\n\nReady\nFinal 🚂";
  let rpcCount = 0;
  setLineReplyTtsRuntime({ gateway: { request() { rpcCount += 1; } } });
  try {
    const projection = prepareBufferedLineReply(raw, { project: "demo" });
    assert.equal(Object.isFrozen(projection), true);
    assert.equal(projection.text, rendered);
    assert.notEqual(projection.text, raw);
    assert.equal(projection.text.includes("Telegram-only detail"), false);
    assert.deepEqual(projection.telegramExtract.telegramTexts, ["Telegram-only detail"]);
    const handle = createLineReplyExpectation({ text: projection.text });
    const expectedHash = createHash("sha256").update(rendered, "utf8").digest("hex");
    assert.equal(handle.semanticReplyFingerprint, expectedHash);
    assert.notEqual(handle.semanticReplyFingerprint, createHash("sha256").update(raw, "utf8").digest("hex"));
    assert.equal(handle.textLength, rendered.length);
    const correlationId = handle.replyCorrelationId;
    // A repeated delivery callback reuses the already-fixed expectation: it
    // must not mint another identity or submit the body to the companion RPC.
    for (let callback = 0; callback < 2; callback += 1) {
      assert.equal(observeLineReplyExpectation(handle).status, "disabled");
      assert.equal(confirmLineReplyExpectation(handle, {
        messageId: "actual-message-1", deliveredChannel: "line", textConfirmedAtMs: 1,
      }).status, "disabled");
      assert.equal(handle.replyCorrelationId, correlationId);
      assert.equal(handle.semanticReplyFingerprint, expectedHash);
    }
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(rpcCount, 0);
  } finally {
    setLineReplyTtsRuntime(null);
  }
});

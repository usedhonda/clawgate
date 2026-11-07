import assert from "node:assert/strict";
import test from "node:test";
import { PassThrough } from "node:stream";
import { MAX_BODY_BYTES, readBody } from "../request-body.js";

function request(headers = {}) {
  const req = new PassThrough();
  req.headers = headers;
  return req;
}

test("body reader handles split UTF-8 and clears listeners after completion", async () => {
  const req = request();
  const result = readBody(req);
  const bytes = Buffer.from('{"text":"会議"}');
  req.write(bytes.subarray(0, 10));
  req.end(bytes.subarray(10));
  assert.equal(await result, '{"text":"会議"}');
  assert.equal(req.listenerCount("data"), 0);
  assert.equal(req.listenerCount("aborted"), 0);
});

test("declared oversized and chunked oversized uploads are rejected before buffering more", async () => {
  const declared = request({ "content-length": String(MAX_BODY_BYTES + 1) });
  await assert.rejects(readBody(declared), { status: 413 });
  assert.equal(declared.listenerCount("data"), 0);

  const chunked = request();
  const result = readBody(chunked);
  const rejection = assert.rejects(result, { status: 413 });
  chunked.write(Buffer.alloc(MAX_BODY_BYTES));
  chunked.write(Buffer.from("x"));
  await rejection;
  assert.equal(chunked.listenerCount("data"), 0);
  assert.equal(chunked.isPaused(), true);
  chunked.destroy();
  declared.destroy();
});

test("aborted requests settle and safely handle a later stream error", async () => {
  const req = request();
  const rejection = assert.rejects(readBody(req), { status: 400 });
  req.emit("aborted");
  await rejection;
  assert.doesNotThrow(() => req.emit("error", new Error("socket reset")));
  req.destroy();
});

test("a stalled request has a complete-body deadline", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const req = request();
  const rejection = assert.rejects(readBody(req), { status: 408 });
  req.write(Buffer.from("{"));
  t.mock.timers.tick(10_001);
  await rejection;
  assert.equal(req.listenerCount("data"), 0);
  req.destroy();
});

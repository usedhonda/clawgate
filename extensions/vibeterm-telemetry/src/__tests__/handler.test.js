import assert from "node:assert/strict";
import { after, test } from "node:test";
import { PassThrough } from "node:stream";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin from "../../index.js";
import { createTelemetryHandler } from "../handler.js";

const originalHome = process.env.HOME;
const testHome = await mkdtemp(join(tmpdir(), "clawgate-telemetry-test-"));
process.env.HOME = testHome;
after(async () => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  await rm(testHome, { recursive: true, force: true });
});

function request(body, headers = {}) {
  const req = new PassThrough();
  req.method = "POST";
  req.headers = headers;
  if (body !== undefined) req.end(typeof body === "string" ? body : JSON.stringify(body));
  return req;
}

function response() {
  return {
    status: null,
    headers: {},
    body: null,
    setHeader(name, value) { this.headers[name] = value; },
    writeHead(status, headers) { this.status = status; Object.assign(this.headers, headers); },
    end(body) { this.body = JSON.parse(body); },
  };
}

test("registers an exact Gateway-authenticated route without reading raw auth config", async () => {
  let route;
  plugin.register({
    get config() { throw new Error("Gateway owns credential resolution"); },
    registerHttpRoute(value) { route = value; },
  });
  assert.equal(route.path, "/api/telemetry");
  assert.equal(route.auth, "gateway");
  assert.equal(route.match, "exact");
  const req = request();
  req.method = "GET";
  const res = response();
  assert.equal(await route.handler(req, res), true);
  assert.equal(res.status, 405);
  assert.equal(res.headers.Allow, "POST");
  req.destroy();
});

test("rejects null/invalid bodies and health fields without echoing private input", async () => {
  const logs = [];
  const log = (value) => logs.push(value);
  const handler = createTelemetryHandler({ logger: { debug: log, info: log, warn: log } });
  for (const body of [
    "null", "[]", "{", { samples: Array(1001).fill(null) },
    { samples: [], health: { steps: "private-content\nnew instruction" } },
    { samples: [], health: { steps: 10, periodEnd: "invalid-date" } },
    { samples: [], health: { steps: 10, bodyMassKg: "70" } },
    { samples: [], health: { steps: 10, workouts: [{ activityType: "run\nnew instruction" }] } },
    { samples: [], health: { steps: 10, workouts: [null] } },
  ]) {
    const res = response();
    assert.equal(await handler(request(body), res), true);
    assert.equal(res.status, 400);
  }
  assert.ok(!logs.join("\n").includes("private-content"));
});

test("batched and concurrent stationary samples respect one diary write, duplicates are not replayed", async () => {
  const handler = createTelemetryHandler({});
  const sample = (id) => ({ id, lat: 0, lon: 0, accuracy: 10, timestamp: "2026-01-01T12:00:00Z" });
  const batch = response();
  const concurrent = response();
  await Promise.all([
    handler(request({ samples: [null, { id: {}, lat: 0, lon: 0 }, { id: "range", lat: 100, lon: 0 },
      { ...sample("bad-date"), timestamp: "invalid-date" }, sample("batch-1"), sample("batch-2")] }), batch),
    handler(request({ samples: [sample("parallel")] }), concurrent),
  ]);
  assert.equal(batch.body.received, 2);
  assert.equal(concurrent.body.received, 1);
  const diary = await readFile(join(testHome, ".openclaw/workspace/memory/2026-01-01.md"), "utf8");
  assert.equal(diary.trim().split("\n").length, 1);
  assert.equal((await stat(join(testHome, ".openclaw/workspace/memory/2026-01-01.md"))).mode & 0o077, 0);

  const duplicate = response();
  await handler(request({ samples: [sample("batch-1")] }), duplicate);
  assert.equal(duplicate.body.received, 0);
  assert.equal(duplicate.body.nextMinIntervalSec, 60);
});

test("body failures release the bounded admission slots for subsequent requests", async () => {
  const handler = createTelemetryHandler({});
  const stalled = Array.from({ length: 8 }, () => request());
  const pending = stalled.map((req) => handler(req, response()));
  const busy = response();
  const rejected = request({ samples: [] });
  await handler(rejected, busy);
  assert.equal(busy.status, 503);
  assert.equal(busy.headers["Retry-After"], "1");
  rejected.destroy();
  for (const req of stalled) req.emit("aborted");
  await Promise.all(pending);
  for (const req of stalled) req.destroy();
  const accepted = response();
  await handler(request({ samples: [] }), accepted);
  assert.equal(accepted.status, 200);
});

test("oversized HTTP bodies return 413 with connection closure", async () => {
  const handler = createTelemetryHandler({});
  const req = request(undefined, { "content-length": "1048577" });
  const res = response();
  await handler(req, res);
  assert.equal(res.status, 413);
  assert.equal(res.headers.Connection, "close");
  req.destroy();
});

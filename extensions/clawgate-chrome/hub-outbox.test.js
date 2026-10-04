import assert from 'node:assert/strict';
import { test } from 'node:test';
import { enqueueHubEntry, flushHubOutbox, hubEventForEntry } from './hub-outbox.js';

function storage() {
  const values = {};
  return {
    async get(defaults) { return { ...defaults, ...values }; },
    async set(next) { Object.assign(values, next); },
    values,
  };
}

const settings = { gatewayURL: 'http://example.invalid', gatewayToken: 'fixture' };
const entry = (id, content = id) => ({ id, userInitiated: true,
  visitedAt: '2026-10-02T00:00:00Z', content });
const accepted = (id) => ({ ok: true, json: async () => ({ ok: true,
  externalId: `chrome:${id}`, status: 'created' }) });
const personalSettings = { personalHubURL: 'https://hub.example.test/', personalHubToken: 'fixture' };
const personalAccepted = (id, overrides = {}) => ({ ok: true, status: 201, json: async () => ({
  storage_receipt: { receipt_version: 1, source: 'chrome', external_id: `chrome:${id}`,
    event_id: '00000000-0000-4000-8000-000000000001', sha256: null, byte_length: 0, ingest_sequence: 1 }, ...overrides,
}) });

test('selected page, visit, and Messenger keep separate domain provenance', () => {
  const base = { id: 'x', visitedAt: '2026-10-02T00:00:00Z' };
  assert.equal(hubEventForEntry({ ...base, userInitiated: true }).domain, 'page');
  assert.equal(hubEventForEntry(base).domain, 'history');
  assert.equal(hubEventForEntry({ ...base, platform: 'messenger', capturedAt: base.visitedAt }).domain,
    'messenger');
});

test('durable outbox preserves failed sends and dequeues only matching committed ACK', async () => {
  const local = storage();
  await enqueueHubEntry(entry('selected-1', 'fixture'), local);
  assert.equal(local.values.personalHubOutbox.length, 1);
  const failed = await flushHubOutbox(settings, local, async () => { throw new Error('offline'); });
  assert.equal(failed.pending, 1);
  const mismatched = await flushHubOutbox(settings, local, async () => ({ ok: true,
    json: async () => ({ ok: true, externalId: 'other', status: 'created' }) }));
  assert.equal(mismatched.pending, 1);
  const accepted = await flushHubOutbox(settings, local, async () => ({ ok: true,
    json: async () => ({ ok: true, externalId: 'chrome:selected-1', status: 'duplicate' }) }));
  assert.equal(accepted.pending, 0);
  assert.deepEqual(local.values.personalHubOutbox, []);
});

test('stalled network does not block a durable enqueue, and late ACK preserves it', async () => {
  const local = storage();
  await enqueueHubEntry(entry('first'), local);
  let release;
  const pending = flushHubOutbox(settings, local, () => new Promise((resolve) => {
    release = () => resolve(accepted('first'));
  }));
  while (!release) await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(await Promise.race([
    enqueueHubEntry(entry('second'), local),
    new Promise((resolve) => setTimeout(() => resolve('blocked'), 50)),
  ]), true);
  release();
  await pending;
  assert.deepEqual(local.values.personalHubOutbox.map((item) => item.external_id), ['chrome:second']);
});

test('timeout retains the exact event and releases a future flush', async () => {
  const local = storage();
  await enqueueHubEntry(entry('timeout', 'original'), local);
  const timedOut = await flushHubOutbox({ ...settings, timeoutMs: 5 }, local, () => new Promise(() => {}));
  assert.equal(timedOut.pending, 1);
  assert.equal(local.values.personalHubOutbox[0].metadata.entry.content, 'original');
  const retried = await flushHubOutbox(settings, local, async () => accepted('timeout'));
  assert.deepEqual(retried, { pending: 0, acked: 1 });
});

test('same external ID with a different body cannot replace or report success', async () => {
  const local = storage();
  assert.equal(await enqueueHubEntry(entry('same', 'one'), local), true);
  assert.equal(await enqueueHubEntry(entry('same', 'two'), local), false);
  assert.equal(local.values.personalHubOutbox[0].metadata.entry.content, 'one');
});

test('storage key order does not create a false payload conflict', async () => {
  const local = storage();
  const original = entry('stable');
  await enqueueHubEntry(original, local);
  const saved = local.values.personalHubOutbox[0];
  local.values.personalHubOutbox[0] = Object.fromEntries(Object.entries(saved).reverse());
  assert.equal(await enqueueHubEntry(original, local), true);
  assert.equal(local.values.personalHubOutbox.length, 1);
});

test('bodyless conflict stays pending without starving a later committed record', async () => {
  const local = storage();
  await enqueueHubEntry(entry('conflict'), local);
  await enqueueHubEntry(entry('later'), local);
  const receipt = await flushHubOutbox(settings, local, async (_url, options) => {
    const id = JSON.parse(options.body).external_id;
    if (id === 'chrome:conflict') return { ok: false, status: 409,
      json: async () => { throw new Error('no JSON body'); } };
    return accepted('later');
  });
  assert.deepEqual(receipt, { pending: 1, acked: 1 });
  assert.equal(local.values.personalHubOutbox[0].external_id, 'chrome:conflict');
});

test('independent Hub requires and matches a committed storage receipt', async () => {
  const local = storage();
  await enqueueHubEntry(entry('personal'), local);
  let seen;
  const result = await flushHubOutbox(personalSettings, local, async (url, options) => {
    seen = { url, options };
    return personalAccepted('personal');
  });
  assert.equal(seen.url, 'https://hub.example.test/v1/events');
  assert.equal(JSON.parse(seen.options.body).external_id, 'chrome:personal');
  assert.deepEqual(result, { pending: 0, acked: 1 });
  assert.equal(local.values.lastPersonalHubReceipt.event_id, '00000000-0000-4000-8000-000000000001');
  assert.equal(local.values.lastPersonalHubReceipt.byte_length, 0);
});

test('mismatched independent receipt retains the exact event', async () => {
  const local = storage();
  await enqueueHubEntry(entry('receipt-mismatch', 'keep'), local);
  const result = await flushHubOutbox(personalSettings, local, async () => personalAccepted('other'));
  assert.deepEqual(result, { pending: 1, acked: 0 });
  assert.equal(local.values.personalHubOutbox[0].metadata.entry.content, 'keep');
});

test('configured independent Hub without token does not fall back to gateway', async () => {
  const local = storage();
  await enqueueHubEntry(entry('no-token'), local);
  let called = false;
  const result = await flushHubOutbox({ ...personalSettings, personalHubToken: '', gatewayURL: 'https://gateway.example/', gatewayToken: 'legacy' }, local, async () => {
    called = true;
    return accepted('no-token');
  });
  assert.deepEqual(result, { pending: 1, acked: 0 });
  assert.equal(called, false);
});

test('invalid independent Hub URL retains queue without gateway fallback', async () => {
  const local = storage();
  await enqueueHubEntry(entry('bad-url'), local);
  const result = await flushHubOutbox({ personalHubURL: 'https://hub.example.test/path', personalHubToken: 'fixture', gatewayURL: 'https://gateway.example/', gatewayToken: 'legacy' }, local, async () => {
    throw new Error('must not use gateway');
  });
  assert.deepEqual(result, { pending: 1, acked: 0 });
});

test('independent selection survives missing settings without legacy fallback', async () => {
  const local = storage();
  await enqueueHubEntry(entry('first-direct'), local);
  await flushHubOutbox(personalSettings, local, async () => personalAccepted('first-direct'));
  await enqueueHubEntry(entry('after-loss'), local);
  let calls = 0;
  const result = await flushHubOutbox(settings, local, async () => {
    calls += 1;
    return accepted('after-loss');
  });
  assert.equal(calls, 0);
  assert.deepEqual(result, { pending: 1, acked: 0 });
});

test('independent receipt rejects malformed event identity', async () => {
  const local = storage();
  await enqueueHubEntry(entry('invalid-id'), local);
  const response = personalAccepted('invalid-id');
  const body = await response.json();
  body.storage_receipt.event_id = 'not-a-hub-uuid';
  response.json = async () => body;
  const result = await flushHubOutbox(personalSettings, local, async () => response);
  assert.deepEqual(result, { pending: 1, acked: 0 });
  assert.equal(local.values.lastPersonalHubReceipt, undefined);
});

test('Messenger captures are immutable versions and a legacy fixed id is re-keyed once', async () => {
  const base = { id: 'messenger:t1', platform: 'messenger', capturedAt: '2026-10-04T01:00:00Z' };
  const a = hubEventForEntry({ ...base, contentSignature: '3-aaa' });
  const b = hubEventForEntry({ ...base, contentSignature: '4-bbb', capturedAt: '2026-10-04T01:05:00Z' });
  assert.notEqual(a.external_id, b.external_id);
  assert.match(a.external_id, /^chrome:messenger:t1:3-aaa:\d+$/);

  const local = storage();
  const legacy = { ...a, external_id: 'chrome:messenger:t1', metadata: { ...a.metadata, entry: { ...base, contentSignature: '3-aaa' } } };
  local.values.personalHubOutbox = [legacy];
  let sent = null;
  await flushHubOutbox(personalSettings, local, async (_url, options) => {
    sent = JSON.parse(options.body); return { ok: false, status: 500, json: async () => ({}) };
  });
  assert.equal(sent.external_id, a.external_id);
  assert.equal(local.values.personalHubOutbox[0].external_id, a.external_id);
});

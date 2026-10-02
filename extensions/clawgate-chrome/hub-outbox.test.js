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

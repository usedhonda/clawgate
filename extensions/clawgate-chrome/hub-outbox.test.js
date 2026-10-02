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

test('selected page, visit, and Messenger keep separate domain provenance', () => {
  const base = { id: 'x', visitedAt: '2026-10-02T00:00:00Z' };
  assert.equal(hubEventForEntry({ ...base, userInitiated: true }).domain, 'page');
  assert.equal(hubEventForEntry(base).domain, 'history');
  assert.equal(hubEventForEntry({ ...base, platform: 'messenger', capturedAt: base.visitedAt }).domain,
    'messenger');
});

test('durable outbox preserves failed sends and dequeues only matching committed ACK', async () => {
  const local = storage();
  const entry = { id: 'selected-1', userInitiated: true, visitedAt: '2026-10-02T00:00:00Z',
    content: 'fixture' };
  await enqueueHubEntry(entry, local);
  assert.equal(local.values.personalHubOutbox.length, 1);
  const settings = { gatewayURL: 'http://example.invalid', gatewayToken: 'fixture' };
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

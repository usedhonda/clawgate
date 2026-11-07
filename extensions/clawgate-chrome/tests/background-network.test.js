const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const background = fs.readFileSync(path.join(root, 'background.js'), 'utf8').replace(/^import .*;\n/gm, '');
const request = fs.readFileSync(path.join(root, 'request.js'), 'utf8').replace(/^export /gm, '');

async function drain() { for (let i = 0; i < 30; i++) await Promise.resolve(); }

function harness(fetch) {
  const noop = () => {};
  const event = () => ({ addListener: noop });
  let now = 1_800_000_000_000;
  let nextId = 0;
  const timers = new Map();
  const values = { gatewayURL: 'https://gateway.example', gatewayToken: 'fixture' };
  const notifications = [];
  const local = {
    get: async (defaults) => ({ ...defaults, ...values }),
    set: async (next) => { Object.assign(values, next); },
  };
  const ctx = {
    URL, AbortController, fetch,
    Date: class extends Date { static now() { return now; } },
    console: { warn: noop },
    setTimeout(fn, ms) { const id = ++nextId; timers.set(id, { fn, at: now + ms, ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
    chrome: {
      runtime: {
        onInstalled: event(), onStartup: event(), onConnect: event(), onMessage: event(),
        sendMessage: async (value) => { notifications.push(value); },
      },
      contextMenus: { onClicked: event() },
      tabs: { onActivated: event(), onUpdated: event() },
      alarms: { onAlarm: event() },
      storage: { onChanged: event(), local },
      action: { setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {} },
    },
  };
  vm.createContext(ctx);
  vm.runInContext(request + '\n' + background, ctx);
  return {
    ctx, timers, values, notifications,
    read(expression) { return vm.runInContext(expression, ctx); },
    async advance(ms) {
      now += ms;
      for (const [id, timer] of [...timers]) {
        if (timer.at <= now) { timers.delete(id); timer.fn(); }
      }
      await drain();
    },
  };
}

const entry = (id) => ({ id, domain: 'page.example', url: `https://page.example/${id}`, title: id });
const ok = (body = {}) => ({ ok: true, status: 200, json: async () => body });

test('concurrent legacy flushes send one copy, and a new capture gets its own bounded follow-up', async () => {
  const pending = [];
  const h = harness((url, options) => new Promise((resolve) => pending.push({ url, options, resolve })));
  h.ctx.enqueuePassiveEntry(entry('first'));
  const first = h.ctx.flushPassiveQueue();
  const concurrent = h.ctx.flushPassiveQueue();
  assert.equal(first, concurrent);
  await drain();
  assert.equal(pending.length, 1);
  assert.equal(pending[0].options.redirect, 'error');
  assert.ok(pending[0].options.signal);

  h.ctx.enqueuePassiveEntry(entry('second'));
  assert.equal(h.ctx.flushPassiveQueue(), first);
  pending[0].resolve(ok());
  await drain();
  assert.equal(pending.length, 2);
  assert.deepEqual(JSON.parse(pending[1].options.body).entries.map((item) => item.id), ['second']);
  pending[1].resolve(ok());
  await first;
  assert.equal(h.read('passiveQueue.length'), 0);
});

test('a timed out capture stays queued, is not replayed in that flight, and ignores a late response', async () => {
  const pending = [];
  const h = harness((url, options) => new Promise((resolve) => pending.push({ options, resolve })));
  h.ctx.enqueuePassiveEntry(entry('original'));
  const flight = h.ctx.flushPassiveQueue();
  h.ctx.flushPassiveQueue();
  await drain();
  await h.advance(10_001);
  await flight;
  assert.equal(pending.length, 1);
  assert.equal(pending[0].options.signal.aborted, true);
  assert.equal(h.read('passiveQueue.length'), 1);
  assert.equal(h.read('passiveFlushFlight'), null);
  pending[0].resolve(ok());
  await drain();
  assert.equal(h.read('passiveQueue.length'), 1, 'late headers cannot settle an uncertain capture');

  h.ctx.fetch = async (_url, options) => {
    assert.equal(JSON.parse(options.body).entries[0].id, 'original');
    return ok();
  };
  await h.ctx.flushPassiveQueue();
  assert.equal(h.read('passiveQueue.length'), 0, 'the existing later retry can still succeed');
});

test('a stalled bootstrap settles and permits polling, without accepting its late config response', async () => {
  let resolveBootstrap;
  let bootstrapSignal;
  const h = harness((url, options) => {
    if (url.endsWith('/v1/openclaw-info')) {
      bootstrapSignal = options.signal;
      return new Promise((resolve) => { resolveBootstrap = resolve; });
    }
    return Promise.resolve(ok({ next_cursor: '7', events: [] }));
  });
  const poll = h.ctx.startPolling();
  await drain();
  await h.advance(10_001);
  await poll;
  assert.equal(bootstrapSignal.aborted, true);
  assert.equal(h.read('pollInFlight'), false);
  assert.equal(h.values.pollCursor, '7');
  assert.ok([...h.timers.values()].some((timer) => timer.ms === 2500));
  resolveBootstrap(ok({ gateway_host: 'late.example', port: 18789, token: 'late-fixture' }));
  await drain();
  assert.equal(h.values.gatewayURL, 'https://gateway.example');
});

test('poll body reads have a deadline, release the in-flight lock and schedule recovery', async () => {
  let signal;
  let cancelled = 0;
  const h = harness(async (_url, options) => {
    signal = options.signal;
    return { ...ok(), json: () => new Promise(() => {}), body: { cancel: async () => { cancelled++; } } };
  });
  h.read('lastGatewayRefreshAt = Date.now()');
  const poll = h.ctx.startPolling();
  await drain();
  await h.advance(10_001);
  await poll;
  assert.equal(signal.aborted, true);
  assert.equal(cancelled, 1);
  assert.equal(h.read('pollInFlight'), false);
  assert.equal(h.values.pollCursor, undefined);
  assert.ok([...h.timers.values()].some((timer) => timer.ms === 5000));
  assert.ok(h.notifications.some((value) => value.bridgeConnected === false));

  h.ctx.fetch = async () => ok({ next_cursor: '8', events: [] });
  await h.advance(5000);
  assert.equal(h.values.pollCursor, '8');
  assert.equal(h.read('pollInFlight'), false);
});

test('poll recovery still gets scheduled when settings-status reporting fails', async () => {
  const h = harness(async () => ok());
  h.ctx.chrome.storage.local.get = async () => { throw new Error('storage unavailable'); };
  await assert.rejects(h.ctx.startPolling(), /storage unavailable/);
  assert.equal(h.read('pollInFlight'), false);
  assert.ok([...h.timers.values()].some((timer) => timer.ms === 5000));
});

test('successful delivery cannot discard a newer sidebar observation', async () => {
  let release;
  const h = harness((_url, options) => new Promise((resolve) => {
    assert.equal(JSON.parse(options.body).threadList.version, 'first');
    release = resolve;
  }));
  h.read('latestThreadList = { version: "first", rows: [] }');
  const send = h.ctx.postMessengerEntries([{ id: 'synthetic-thread' }], h.values);
  await drain();
  h.read('latestThreadList = { version: "second", rows: [] }');
  release(ok());
  await send;
  assert.equal(h.read('latestThreadList.version'), 'second');
});

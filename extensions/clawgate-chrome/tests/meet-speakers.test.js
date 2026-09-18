const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const SOURCE = fs.readFileSync(path.resolve(__dirname, '..', 'meet.js'), 'utf8');

// A Meet page reduced to what meet.js reads: the leave-call button and the
// participant tiles (id, name span, self marker, speaking class).
function makePage() {
  let now = 1_000_000;
  const intervals = [];
  const sent = [];
  const page = { inCall: true, tiles: [] };

  function tile({ id, name, self = false, speaking = false }) {
    return {
      id, name, self, speaking,
      getAttribute: (k) => (k === 'data-participant-id' ? id : null),
      hasAttribute: (k) => k === 'data-self-name' && self,
      classList: { contains: (cls) => speaking && cls === 'Oaajhc' },
      querySelector(sel) {
        if (sel === 'span.notranslate') return name == null ? null : { textContent: name };
        if (sel === '[data-self-name]') return null;
        return null;   // speaking class lives on the tile itself here
      },
    };
  }

  const document = {
    querySelector: (sel) => (sel.includes('Leave call') && page.inCall ? {} : null),
    querySelectorAll: (sel) => ({ forEach: (fn) => (sel === '[data-participant-id]' ? page.tiles : []).forEach(fn) }),
  };
  const context = {
    document,
    window: { addEventListener() {} },
    chrome: { runtime: { sendMessage: (m) => sent.push(m) } },
    Date: { now: () => now },
    setInterval: (fn, ms) => intervals.push({ fn, ms }),
  };
  vm.runInNewContext(SOURCE, context);

  const tick = (ms) => {
    now += ms;
    intervals.filter((i) => i.ms === 250).forEach((i) => i.fn());
  };
  const heartbeat = () => intervals.filter((i) => i.ms === 10_000).forEach((i) => i.fn());
  return { page, tile, sent, tick, heartbeat, edges: () => sent.filter((m) => m.speakerEdge).map((m) => m.speakerEdge) };
}

test('a lit tile reports a start edge at once, and a stop after the grace period', () => {
  const p = makePage();
  p.page.tiles = [p.tile({ id: 'a', name: '田中', speaking: true })];
  p.tick(250);
  assert.deepEqual(p.edges().map((e) => [e.name, e.speaking]), [['田中', true]]);

  p.page.tiles = [p.tile({ id: 'a', name: '田中', speaking: false })];
  p.tick(250);
  assert.equal(p.edges().length, 1, 'still inside the 750ms grace');
  p.tick(750);
  const edges = p.edges();
  assert.deepEqual(edges.map((e) => [e.name, e.speaking]), [['田中', true], ['田中', false]]);
  assert.equal(edges[1].at, 1_000_250, 'stop is stamped at the last lit time, not when noticed');
});

test('self tiles, unnamed tiles and junk names never produce edges', () => {
  const p = makePage();
  p.page.tiles = [
    p.tile({ id: 'me', name: '自分', self: true, speaking: true }),
    p.tile({ id: 'x', name: null, speaking: true }),
    p.tile({ id: 'y', name: 'Google Participant (abc)', speaking: true }),
  ];
  p.tick(250);
  assert.deepEqual(p.edges(), []);
});

test('nested tiles of one participant count once in the heartbeat signal', () => {
  const p = makePage();
  p.page.tiles = [
    p.tile({ id: 'a', name: '田中', speaking: true }),
    p.tile({ id: 'a', name: '田中', speaking: true }),
    p.tile({ id: 'b', name: '佐藤' }),
  ];
  p.tick(250);
  p.heartbeat();
  const signal = p.sent.filter((m) => m.signal).pop().signal;
  assert.deepEqual(JSON.parse(JSON.stringify(signal)), { tiles: 2, named: 2, knownClassHits: 1 });
});

test('leaving the call closes open speakers and reports the end once', () => {
  const p = makePage();
  p.page.tiles = [p.tile({ id: 'a', name: '田中', speaking: true })];
  p.tick(250);
  p.page.inCall = false;
  p.heartbeat();
  p.heartbeat();
  assert.deepEqual(p.edges().map((e) => [e.name, e.speaking]), [['田中', true], ['田中', false]]);
  assert.equal(p.sent.filter((m) => m.inCall === false).length, 1);
});

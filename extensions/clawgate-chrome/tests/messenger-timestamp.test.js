const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const EXTENSION_ROOT = path.resolve(__dirname, '..');

// Minimal sandbox: content.js only needs enough of the DOM to install its
// diagnostic marker and register a runtime listener at load time.
function loadContentScript() {
  const root = { appendChild() {}, setAttribute() {} };
  const context = {
    chrome: { runtime: { onMessage: { addListener() {} } } },
    document: {
      documentElement: root,
      body: root,
      head: { appendChild() {}, querySelector() { return null; } },
      createElement() { return { setAttribute() {} }; },
      querySelector() { return null; },
    },
    HTMLMetaElement: function HTMLMetaElement() {},
    window: {
      location: { hostname: 'www.messenger.com', pathname: '/t/1' },
      addEventListener() {},
      removeEventListener() {},
    },
    setTimeout,
    clearTimeout,
    URL,
    console,
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(EXTENSION_ROOT, 'content.js'), 'utf8'), context);
  return context;
}

function parse(context, raw) {
  return vm.runInContext(`parseMessengerTimestamp(${JSON.stringify(raw)})`, context);
}

test('all three live aria-label time formats resolve to an absolute instant', () => {
  const context = loadContentScript();

  // Older than about a week: no weekday.
  const plain = parse(context, '2024年3月11日 19:32');
  assert.ok(plain, 'dated label without a weekday must still parse');
  assert.equal(plain.getFullYear(), 2024);
  assert.equal(plain.getMonth(), 2);
  assert.equal(plain.getDate(), 11);
  assert.equal(plain.getHours(), 19);
  assert.equal(plain.getMinutes(), 32);

  // Within about a week: weekday in parentheses. This shape used to fall
  // through to the capture-time placeholder.
  const weekday = parse(context, '2026年8月14日(金) 11:02');
  assert.ok(weekday, 'dated label with a weekday must parse');
  assert.equal(weekday.getFullYear(), 2026);
  assert.equal(weekday.getMonth(), 7);
  assert.equal(weekday.getDate(), 14);
  assert.equal(weekday.getHours(), 11);
  assert.equal(weekday.getMinutes(), 2);

  // Today: time only. Resolved against the capture date.
  const now = new Date();
  const past = new Date(now.getTime() - 2 * 60 * 60 * 1000);
  const label = `${past.getHours()}:${String(past.getMinutes()).padStart(2, '0')}`;
  const timeOnly = parse(context, label);
  assert.ok(timeOnly, 'a bare H:MM label must parse');
  assert.equal(timeOnly.getFullYear(), past.getFullYear());
  assert.equal(timeOnly.getMonth(), past.getMonth());
  assert.equal(timeOnly.getDate(), past.getDate());
  assert.equal(timeOnly.getHours(), past.getHours());
  assert.equal(timeOnly.getMinutes(), past.getMinutes());

  assert.equal(parse(context, 'たった今'), null, 'an unrecognised label stays approximate');
});

test('a bare time that resolves into the future rolls back a day', () => {
  const context = loadContentScript();
  const now = new Date();
  const ahead = new Date(now.getTime() + 3 * 60 * 60 * 1000);
  const label = `${ahead.getHours()}:${String(ahead.getMinutes()).padStart(2, '0')}`;
  const parsed = parse(context, label);
  assert.ok(parsed, 'a bare H:MM label must parse');
  assert.ok(parsed.getTime() <= now.getTime() + 60000, 'must never claim a message from the future');
  assert.equal(parsed.getHours(), ahead.getHours());
});

test('the epoch-stamped E2EE system notice is rejected as a placeholder', () => {
  const context = loadContentScript();
  const implausible = (raw) => vm.runInContext(`hasImplausibleYear(${JSON.stringify(raw)})`, context);
  assert.equal(implausible('1970年1月1日 7:30'), true);
  assert.equal(implausible('2026年8月14日(金) 11:02'), false);
  assert.equal(implausible('2024年3月11日 19:32'), false);
  assert.equal(implausible('18:51'), false, 'a bare time carries no year to judge');
});

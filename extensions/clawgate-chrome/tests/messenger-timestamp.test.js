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

function bareTimeLabel(date) {
  return `${date.getHours()}:${String(date.getMinutes()).padStart(2, '0')}`;
}

test('all three live aria-label time formats resolve to an absolute instant', () => {
  const context = loadContentScript();

  // Older than about a week: no weekday.
  const plain = parse(context, '2024年3月11日 19:32');
  assert.ok(plain, 'dated label without a weekday must still parse');
  assert.equal(plain.precision, 'exact');
  assert.equal(plain.date.getFullYear(), 2024);
  assert.equal(plain.date.getMonth(), 2);
  assert.equal(plain.date.getDate(), 11);
  assert.equal(plain.date.getHours(), 19);
  assert.equal(plain.date.getMinutes(), 32);

  // Within about a week: weekday in parentheses. This shape used to fall
  // through to the capture-time placeholder.
  const weekday = parse(context, '2026年8月14日(金) 11:02');
  assert.ok(weekday, 'dated label with a weekday must parse');
  assert.equal(weekday.precision, 'exact');
  assert.equal(weekday.date.getFullYear(), 2026);
  assert.equal(weekday.date.getMonth(), 7);
  assert.equal(weekday.date.getDate(), 14);
  assert.equal(weekday.date.getHours(), 11);
  assert.equal(weekday.date.getMinutes(), 2);

  // Today: time only. The date is reconstructed from the capture date, so it
  // must say so rather than pass as a stated timestamp.
  const past = new Date(Date.now() - 2 * 60 * 60 * 1000);
  const timeOnly = parse(context, bareTimeLabel(past));
  assert.ok(timeOnly, 'a bare H:MM label must parse');
  assert.equal(timeOnly.precision, 'inferred_date');
  assert.equal(timeOnly.date.getFullYear(), past.getFullYear());
  assert.equal(timeOnly.date.getMonth(), past.getMonth());
  assert.equal(timeOnly.date.getDate(), past.getDate());
  assert.equal(timeOnly.date.getHours(), past.getHours());
  assert.equal(timeOnly.date.getMinutes(), past.getMinutes());

  assert.equal(parse(context, 'たった今'), null, 'an unrecognised label stays approximate');
});

test('a reconstructed date and the dated label it becomes tomorrow share one id', () => {
  const context = loadContentScript();
  // The whole point of reconstructing the date: the same message re-captured
  // once Messenger relabels it must land on the existing row, not a new one.
  const past = new Date(Date.now() - 3 * 60 * 60 * 1000);
  const today = parse(context, bareTimeLabel(past));
  const dated = parse(context, `${past.getFullYear()}年${past.getMonth() + 1}月${past.getDate()}日(火) ${bareTimeLabel(past)}`);
  assert.ok(today && dated);
  assert.notEqual(today.precision, dated.precision, 'the two labels are not equally trustworthy');
  assert.equal(today.date.toISOString(), dated.date.toISOString(), 'but they must resolve to one instant');

  const idOf = (sentAt) => vm.runInContext(
    `computeMessengerMessageId("42", ${JSON.stringify({ sentAt, fromSelf: false, text: 'hello' })})`,
    context
  );
  assert.equal(idOf(today.date.toISOString()), idOf(dated.date.toISOString()));
});

test('a bare time that resolves into the future rolls back a day', () => {
  const context = loadContentScript();
  const now = new Date();
  const ahead = new Date(now.getTime() + 3 * 60 * 60 * 1000);
  const parsed = parse(context, bareTimeLabel(ahead));
  assert.ok(parsed, 'a bare H:MM label must parse');
  assert.ok(parsed.date.getTime() <= now.getTime() + 60000, 'must never claim a message from the future');
  assert.equal(parsed.date.getHours(), ahead.getHours());
});

test('the epoch-stamped E2EE system notice is rejected as a placeholder', () => {
  const context = loadContentScript();
  const implausible = (raw) => vm.runInContext(`hasImplausibleYear(${JSON.stringify(raw)})`, context);
  assert.equal(implausible('1970年1月1日 7:30'), true);
  assert.equal(implausible('2026年8月14日(金) 11:02'), false);
  assert.equal(implausible('2024年3月11日 19:32'), false);
  assert.equal(implausible('18:51'), false, 'a bare time carries no year to judge');
});

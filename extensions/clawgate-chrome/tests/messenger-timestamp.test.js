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
      querySelectorAll() { return []; },
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

test('the contact name is the name, not the landmark label wrapped around it', () => {
  const context = loadContentScript();
  const withHeadings = (headings) => {
    context.document.querySelectorAll = () => headings.map((text) => ({ textContent: text }));
    return vm.runInContext('extractMessengerContactName()', context);
  };

  // 1:1 thread: the landmark prefixes the name.
  assert.equal(withHeadings(['スレッド: 山田 花子', '山田 花子', 'メッセージ']), '山田 花子');
  // Group thread: the landmark wraps the name in a phrase instead.
  assert.equal(withHeadings(['旅行の相談というタイトルのスレッド', '旅行の相談', 'メッセージ']), '旅行の相談');
  // Captured before the plain heading rendered: strip the decoration rather
  // than filing the contact under Messenger's label. Observed in production —
  // a real capture stored "スレッド: 佐藤 次郎" as the contact name.
  assert.equal(withHeadings(['スレッド: 山田 花子', 'メッセージ']), '山田 花子');
  assert.equal(withHeadings(['旅行の相談というタイトルのスレッド']), '旅行の相談');
  assert.equal(withHeadings([]), '');
});

test('thread state is read at the strength the DOM actually states it', () => {
  const context = loadContentScript();
  const fakeArticle = (labels, alts = [], headings = []) => ({
    querySelectorAll(selector) {
      if (selector === 'img[alt]') return alts.map((alt) => ({ alt }));
      if (selector.includes('heading')) return headings.map((textContent) => ({ textContent }));
      return labels.map((label) => ({ getAttribute: () => label }));
    },
  });
  // Values cross a vm realm boundary, so their prototypes differ from this
  // realm's — compare the data, not the object identity.
  const call = (fn, article) => {
    context.__article = article;
    return JSON.parse(vm.runInContext(`JSON.stringify(${fn}(__article) ?? null)`, context));
  };

  // The affordance button sits on every message and means nothing was reacted.
  assert.equal(call('extractMessengerReactions', fakeArticle(['絵文字でリアクションする'])), null);
  assert.deepEqual(
    call('extractMessengerReactions', fakeArticle(['絵文字付きのリアクションが3件ありました: 👍、❤️。リアクションした人をチェックしよう。'])),
    { count: 3, emoji: ['👍', '❤️'] }
  );

  // A reader whose time does not parse still counts as a reader, but must not
  // be given the capture time as if it were a read time.
  assert.deepEqual(
    call('extractMessengerReadBy', fakeArticle([], ['田中 健一さんがついさっきに閲覧'])),
    [{ reader: '田中 健一', readAt: null, readAtPrecision: 'approximate' }]
  );
  const dated = call('extractMessengerReadBy', fakeArticle([], ['小林 誠さんが2026年4月1日 7:56に閲覧']));
  assert.equal(dated.length, 1);
  assert.equal(dated[0].readAtPrecision, 'exact');

  assert.equal(
    call('extractMessengerReplyToName', fakeArticle([], [], ['鈴木 一郎さんがAlex Riveraさんに返信しました'])),
    'Alex Rivera'
  );

  // Title and domain are concatenated with no delimiter; the label is kept whole.
  assert.deepEqual(
    call('extractMessengerAttachments', fakeArticle(['添付を開く: 2026Q3 Product Update | Noteswww.example.com'])),
    [{ kind: 'link', label: '2026Q3 Product Update | Noteswww.example.com' }]
  );
});

test('a capture is refused while the screen still shows another thread', () => {
  const context = loadContentScript();
  const withMarkedRow = (href) => {
    context.document.querySelector = (selector) => {
      if (selector !== '[role="grid"] [aria-current="page"]') return null;
      if (href === null) return null;
      return {
        closest: () => ({ querySelectorAll: () => [{ getAttribute: () => href }] }),
        querySelectorAll: () => [{ getAttribute: () => href }],
        getAttribute: () => href,
      };
    };
    return vm.runInContext('extractMessengerOpenThreadId()', context);
  };

  assert.equal(withMarkedRow('/t/1352134236563347/'), '1352134236563347');
  assert.equal(withMarkedRow('/e2ee/t/7467967463261857/'), '7467967463261857');
  // No marker: fall back to the URL rather than block every capture.
  assert.equal(withMarkedRow(null), '');
});

test('the epoch-stamped E2EE system notice is rejected as a placeholder', () => {
  const context = loadContentScript();
  const implausible = (raw) => vm.runInContext(`hasImplausibleYear(${JSON.stringify(raw)})`, context);
  assert.equal(implausible('1970年1月1日 7:30'), true);
  assert.equal(implausible('2026年8月14日(金) 11:02'), false);
  assert.equal(implausible('2024年3月11日 19:32'), false);
  assert.equal(implausible('18:51'), false, 'a bare time carries no year to judge');
});

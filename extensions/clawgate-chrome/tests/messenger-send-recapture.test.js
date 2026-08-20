const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const EXTENSION_ROOT = path.resolve(__dirname, '..');
const CONTENT_PATH = process.env.CLAWGATE_CONTENT_PATH || path.join(EXTENSION_ROOT, 'content.js');

// A conversation is a moving target: Messenger replaces the message log when
// another thread is opened, and adds a row before it carries a timestamp. The
// harness models just those two behaviours plus a clock, so the tests can pin
// down when a recapture is asked for without standing up a page.
function makeHarness() {
  const notifications = [];
  const observers = [];
  const listeners = new Map();
  const listenerAdds = [];
  const listenerRemoves = [];
  let now = 0;
  let nextTimerId = 1;
  const timers = new Map();

  class FakeElement {
    constructor(attrs = {}, text = '') {
      this.attrs = attrs;
      this.nodeType = 1;
      this.textContent = text;
    }
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
    }
    closest(selector) {
      return this.matchesSelector(selector) ? this : null;
    }
    matchesSelector(selector) {
      if (selector === '[aria-label]') return this.attrs['aria-label'] != null;
      return this.selfSelector === selector;
    }
  }

  const composer = new FakeElement({ 'aria-label': 'テスト相手に書く' }, '');
  composer.selfSelector = '[role="main"] [role="textbox"][contenteditable="true"]';
  const main = new FakeElement();
  const state = { log: new FakeElement(), main, composer };

  const noop = () => {};
  const head = { appendChild: noop, querySelector: () => null };
  const document = {
    documentElement: { setAttribute: noop, appendChild: noop },
    body: main,
    head,
    createElement: () => ({ setAttribute: noop }),
    querySelector(selector) {
      if (selector === '[role="main"] [role="log"]' || selector === '[role="log"]') return state.log;
      if (selector === '[role="main"]') return state.main;
      if (selector === state.composer.selfSelector) return state.composer;
      return null;
    },
    querySelectorAll: () => [],
    addEventListener(type, handler, capture) {
      listenerAdds.push(type);
      listeners.set(type, { handler, capture });
    },
    removeEventListener(type) {
      listenerRemoves.push(type);
      listeners.delete(type);
    },
  };

  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.observed = [];
      this.disconnected = false;
      observers.push(this);
    }
    observe(target, options) {
      this.observed.push({ target, options });
    }
    disconnect() {
      this.disconnected = true;
    }
  }

  const context = {
    chrome: {
      runtime: {
        id: 'test',
        onMessage: { addListener: noop, removeListener: noop },
        sendMessage(message, callback) {
          notifications.push(message);
          if (typeof callback === 'function') callback();
        },
      },
    },
    document,
    HTMLMetaElement: function HTMLMetaElement() {},
    HTMLIFrameElement: function HTMLIFrameElement() {},
    MutationObserver: FakeMutationObserver,
    window: {
      location: { hostname: 'www.messenger.com', pathname: '/t/1' },
      addEventListener: noop,
      removeEventListener: noop,
    },
    setTimeout(fn, delay) {
      const id = nextTimerId++;
      timers.set(id, { fn, at: now + (delay || 0) });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    URL,
    console,
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(CONTENT_PATH, 'utf8'), context);

  return {
    context,
    state,
    notifications,
    observers,
    listeners,
    // The root observer owns lifecycle; the log observer owns message changes.
    rootObserver: () => observers[0],
    logObserver: () => observers[observers.length - 1],
    fire(observer) {
      observer.callback([], observer);
    },
    dispatch(type, event) {
      const entry = listeners.get(type);
      assert.ok(entry, `no ${type} listener registered`);
      entry.handler(event);
    },
    advance(ms) {
      now += ms;
      for (const [id, timer] of [...timers.entries()].sort((a, b) => a[1].at - b[1].at)) {
        if (timer.at <= now) {
          timers.delete(id);
          timer.fn();
        }
      }
    },
    pendingTimers: () => timers.size,
    listenerAdds,
    listenerRemoves,
  };
}

const composerEvent = (harness, overrides = {}) => ({
  key: 'Enter',
  shiftKey: false,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  isComposing: false,
  keyCode: 13,
  target: harness.state.composer,
  ...overrides,
});

test('sending asks for a recapture more than once, because the timestamp lands late', () => {
  const h = makeHarness();
  h.dispatch('keydown', composerEvent(h));

  assert.equal(h.notifications.length, 0, 'nothing is sent at the instant of the keypress');
  h.advance(700);
  assert.equal(h.notifications.length, 1, 'a first look once the row is likely present');
  h.advance(6000);
  assert.ok(h.notifications.length >= 3, 'and later looks to catch the settled timestamp');
  for (const message of h.notifications) {
    assert.deepEqual({ ...message }, { type: 'messenger_content_changed' },
      'the content script only reports a change; the signature still decides whether anything is sent');
  }
});

test('a click on a send control and a form submit both count as sending', () => {
  const h = makeHarness();
  const sendButton = new (h.state.composer.constructor)({ 'aria-label': '「いいね！」を送信' });
  h.dispatch('click', { target: sendButton });
  h.advance(700);
  assert.equal(h.notifications.length, 1);

  const other = new (h.state.composer.constructor)({ 'aria-label': '絵文字を選択' });
  h.dispatch('click', { target: other });
  h.advance(7000);
  const afterUnrelatedClick = h.notifications.length;

  h.dispatch('submit', {});
  h.advance(700);
  assert.equal(h.notifications.length, afterUnrelatedClick + 1, 'submit asks for a look');
});

test('composing with an IME, or a newline, is not a send', () => {
  const h = makeHarness();
  h.dispatch('keydown', composerEvent(h, { isComposing: true }));
  h.dispatch('keydown', composerEvent(h, { keyCode: 229 }));
  h.dispatch('keydown', composerEvent(h, { shiftKey: true }));
  h.dispatch('keydown', composerEvent(h, { metaKey: true }));
  h.dispatch('keydown', composerEvent(h, { key: 'a' }));
  h.dispatch('keydown', composerEvent(h, { target: new (h.state.composer.constructor)({}) }));
  h.advance(10000);
  assert.equal(h.notifications.length, 0, 'accepting an IME candidate must not be read as sending');
});

test('the log observer follows the conversation when Messenger replaces it', () => {
  const h = makeHarness();
  const firstLog = h.observers[h.observers.length - 1];
  assert.equal(firstLog.observed[0].target, h.state.log);
  assert.equal(firstLog.observed[0].options.attributes, true,
    'a row gets its timestamp as an attribute change, so attributes must be watched');

  // Opening another conversation: Messenger swaps the container out.
  h.state.log = new (h.state.composer.constructor)();
  h.fire(h.rootObserver());

  const secondLog = h.observers[h.observers.length - 1];
  assert.notEqual(secondLog, firstLog, 'a new observer takes over');
  assert.equal(firstLog.disconnected, true, 'and the stale one is released');
  assert.equal(secondLog.observed[0].target, h.state.log);

  // The whole point: a message arriving in the new conversation is noticed.
  h.notifications.length = 0;
  h.fire(secondLog);
  h.advance(2500);
  assert.equal(h.notifications.length, 1, 'a change in the current conversation reaches the worker');
});

test('an unchanged conversation is not re-observed, and sends do not stack timers', () => {
  const h = makeHarness();
  const before = h.observers.length;
  h.fire(h.rootObserver());
  h.fire(h.rootObserver());
  assert.equal(h.observers.length, before, 'the same container is never observed twice');

  h.dispatch('keydown', composerEvent(h));
  const afterOneSend = h.pendingTimers();
  h.dispatch('keydown', composerEvent(h));
  h.dispatch('keydown', composerEvent(h));
  assert.equal(h.pendingTimers(), afterOneSend, 'a burst of sends restarts the ladder rather than piling on');
  h.advance(10000);
  assert.ok(h.notifications.length <= 4, 'the ladder stays bounded');
  assert.equal(h.pendingTimers(), 0, 'and leaves nothing pending');
});

test('the same conversation re-rendering is not news', () => {
  const h = makeHarness();
  h.notifications.length = 0;
  // Opening a thread renders it in stages; every stage is a root mutation.
  for (let i = 0; i < 8; i += 1) {
    h.fire(h.rootObserver());
  }
  h.advance(10000);
  assert.equal(h.notifications.length, 0,
    'the log observer already reports what this conversation does; the root must not report it again');

  // A swapped-in conversation is news, exactly once.
  h.state.log = new (h.state.composer.constructor)();
  h.fire(h.rootObserver());
  h.fire(h.rootObserver());
  h.advance(2500);
  assert.equal(h.notifications.length, 1, 'one notification for the switch, not one per render step');
});

test('switching to a conversation with an empty composer is not a send', () => {
  const h = makeHarness();
  h.state.composer.textContent = 'a draft left in this thread';
  h.fire(h.rootObserver());
  h.notifications.length = 0;

  // Opening another conversation swaps the composer, and the new one is empty.
  const fresh = new (h.state.composer.constructor)({}, '');
  fresh.selfSelector = h.state.composer.selfSelector;
  h.state.composer = fresh;
  h.state.log = new (h.state.composer.constructor)();
  h.fire(h.rootObserver());
  h.advance(10000);

  const switchNotifications = h.notifications.length;
  assert.ok(switchNotifications <= 1,
    'the switch itself may ask once, but the abandoned draft must not read as a send');

  // The primed composer still reports a real send afterwards.
  h.notifications.length = 0;
  fresh.textContent = 'a reply';
  h.fire(h.rootObserver());
  fresh.textContent = '';
  h.fire(h.rootObserver());
  h.advance(700);
  assert.equal(h.notifications.length, 1, 'sending from the new conversation still counts');
});

test('capturing a conversation does not stop the extension from watching it', () => {
  const h = makeHarness();
  const logObserver = h.logObserver();

  // Every successful extraction runs this: it releases the OCR frame and the
  // ports that served that one extraction. Watching the conversation is not
  // part of that, and folding it in silently ended monitoring after the very
  // first capture.
  vm.runInContext('teardownExtensionBindings()', h.context);

  assert.equal(logObserver.disconnected, false, 'the conversation is still being watched');
  h.notifications.length = 0;
  h.fire(logObserver);
  h.advance(2500);
  assert.equal(h.notifications.length, 1, 'a later message still reaches the worker');

  h.dispatch('keydown', composerEvent(h));
  h.advance(700);
  assert.equal(h.notifications.length, 2, 'and a later send still triggers a recapture');
});

test('ending the injected session does release the watchers', () => {
  const h = makeHarness();
  const rootObserver = h.rootObserver();
  const logObserver = h.logObserver();
  h.dispatch('keydown', composerEvent(h));

  vm.runInContext('finalizeInjectedSession()', h.context);

  assert.equal(rootObserver.disconnected, true);
  assert.equal(logObserver.disconnected, true);
  assert.equal(h.pendingTimers(), 0);
  h.advance(10000);
  assert.equal(h.notifications.length, 0);
});

test('a re-injected content script takes over instead of doubling up', () => {
  const h = makeHarness();
  const teardown = h.context.globalThis
    ? h.context.globalThis.__clawgateMessengerTeardown
    : h.context.__clawgateMessengerTeardown;
  assert.equal(typeof teardown, 'function', 'the instance publishes how to release its bindings');

  const rootObserver = h.rootObserver();
  const logObserver = h.logObserver();
  h.dispatch('keydown', composerEvent(h));
  assert.ok(h.pendingTimers() > 0);

  teardown();

  assert.equal(rootObserver.disconnected, true, 'the lifecycle observer is released');
  assert.equal(logObserver.disconnected, true, 'the log observer is released');
  assert.equal(h.pendingTimers(), 0, 'pending recaptures are dropped');
  for (const type of ['keydown', 'click', 'submit']) {
    assert.ok(h.listenerRemoves.includes(type), `${type} listener is removed`);
  }
  h.advance(10000);
  assert.equal(h.notifications.length, 0, 'a released instance goes quiet');
});

test('emptying the composer is treated as a send, whatever emptied it', () => {
  const h = makeHarness();
  h.state.composer.textContent = 'draft';
  h.fire(h.rootObserver());
  h.notifications.length = 0;

  h.state.composer.textContent = '';
  h.fire(h.rootObserver());
  h.advance(700);
  assert.equal(h.notifications.length, 1, 'the box going empty is the send signal that needs no button name');
});

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const EXTENSION_ROOT = path.resolve(__dirname, '..');

function makeEventTarget() {
  const listeners = new Map();
  return {
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    removeEventListener(type, listener) {
      if (listeners.get(type) === listener) {
        listeners.delete(type);
      }
    },
    dispatchEvent(event) {
      listeners.get(event.type)?.(event);
    },
  };
}

class FakeIFrame {
  constructor() {
    this.messages = [];
    this.contentWindow = {
      postMessage: (payload, targetOrigin) => {
        if (targetOrigin !== '*') {
          throw new Error('target origin mismatch');
        }
        this.messages.push({ payload, targetOrigin });
      },
    };
    this.isConnected = false;
    this.listeners = new Map();
    this.style = {};
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  setAttribute() {}

  remove() {
    this.isConnected = false;
  }

  dispatch(type) {
    this.listeners.get(type)?.({ type });
  }
}

class FakeMeta {
  setAttribute() {}
}

function loadContentScript() {
  const windowTarget = makeEventTarget();
  const root = {
    appendChild(node) {
      node.isConnected = true;
      queueMicrotask(() => node.dispatch('load'));
    },
    setAttribute() {},
  };
  const head = {
    appendChild() {},
    querySelector() {
      return null;
    },
  };
  const hostFrame = new FakeIFrame();
  hostFrame.isConnected = true;
  const runtimeListeners = [];
  let portMessageHandler = null;
  let lastFrame = null;

  const document = {
    documentElement: root,
    body: root,
    head,
    getElementById() {
      return hostFrame;
    },
    createElement(tagName) {
      if (tagName === 'iframe') {
        const frame = new FakeIFrame();
        lastFrame = frame;
        return frame;
      }
      if (tagName === 'meta') {
        return new FakeMeta();
      }
      throw new Error(`Unexpected element: ${tagName}`);
    },
  };

  const runtime = {
    onMessage: {
      addListener(listener) {
        runtimeListeners.push(listener);
      },
      removeListener() {},
    },
    connect() {
      const port = {
        onMessage: {
          addListener(listener) {
            portMessageHandler = listener;
          },
        },
        onDisconnect: {
          addListener() {},
        },
        postMessage() {
          queueMicrotask(() => portMessageHandler({
            ok: true,
            dataUrl: 'data:image/png;base64,AAAA',
            sandboxUrl: 'chrome-extension://test/sandbox/ocr.html',
          }));
        },
        disconnect() {},
      };
      return port;
    },
  };

  const context = {
    chrome: { runtime },
    document,
    HTMLIFrameElement: FakeIFrame,
    HTMLMetaElement: FakeMeta,
    window: Object.assign(windowTarget, {
      innerHeight: 1000,
      innerWidth: 1000,
      setTimeout,
      clearTimeout,
    }),
    setTimeout,
    clearTimeout,
    queueMicrotask,
    URL,
    console,
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(EXTENSION_ROOT, 'content.js'), 'utf8'), context);

  return {
    context,
    frame() {
      return lastFrame;
    },
    hostFrame,
    dispatchMessage(event) {
      windowTarget.dispatchEvent({ type: 'message', ...event });
    },
  };
}

function loadSandboxScript() {
  const parent = {
    messages: [],
    postMessage(payload, targetOrigin) {
      this.messages.push({ payload, targetOrigin });
    },
  };
  const windowTarget = makeEventTarget();
  windowTarget.parent = parent;
  const context = {
    window: windowTarget,
    console,
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(EXTENSION_ROOT, 'sandbox/ocr.js'), 'utf8'), context);
  return { context, parent, windowTarget };
}

test('wildcard dispatch fixes opaque sandbox target while forged results remain rejected', async () => {
  const harness = loadContentScript();
  const request = vm.runInContext('extractOCRText("https://pro.musixmatch.com/image.png")', harness.context);

  await new Promise((resolve) => setImmediate(resolve));
  const frame = harness.frame();
  assert.ok(frame, 'OCR frame should be created by the owned session');
  assert.notEqual(frame, harness.hostFrame, 'a host-page iframe with the same id must not be adopted');

  assert.equal(frame.messages.length, 1);
  const sent = frame.messages[0];
  assert.equal(sent.targetOrigin, '*');
  assert.throws(() => frame.contentWindow.postMessage(sent.payload, 'chrome-extension://test'), /target origin mismatch/);

  const forgedSource = {};
  harness.dispatchMessage({
    source: forgedSource,
    origin: 'https://pro.musixmatch.com',
    data: { type: 'clawgate_ocr_result', id: sent.payload.id, ok: true, text: 'forged' },
  });
  const validResult = { type: 'clawgate_ocr_result', id: sent.payload.id, ok: true, text: '  trusted text  ' };
  vm.runInContext(
    `handleSandboxMessage({ source: ocrSandboxFrame.contentWindow, origin: 'null', data: ${JSON.stringify(validResult)} })`,
    harness.context,
  );

  assert.equal(await request, 'trusted text');
});

test('sandbox ignores requests from non-parent sources and invalid payloads', async () => {
  const harness = loadSandboxScript();

  const request = {
    type: 'clawgate_ocr_request',
    id: 'ocr-1',
    imageDataUrl: 'data:image/png;base64,AAAA',
  };
  harness.windowTarget.dispatchEvent({ type: 'message', source: {}, origin: 'https://pro.musixmatch.com', data: request });
  harness.windowTarget.dispatchEvent({ type: 'message', source: harness.parent, origin: 'https://pro.musixmatch.com', data: { ...request, imageDataUrl: 42 } });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(harness.parent.messages.length, 0);
});

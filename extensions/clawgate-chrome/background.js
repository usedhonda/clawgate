const DEFAULT_SETTINGS = {
  bridgePort: 8765,
  gatewayURL: '',
  gatewayToken: '',
};

const CONTEXT_MENU_ID = 'clawgate-send-to-chi';
const POLL_INTERVAL_MS = 2500;
const POLL_ERROR_BACKOFF_MS = 5000;

let cursor = '';
let pollTimer = null;
let pollInFlight = false;

chrome.runtime.onInstalled.addListener(async () => {
  await ensureDefaults();
  await createContextMenu();
  await restoreCursor();
  await refreshBadge();
  startPolling();
});

chrome.runtime.onStartup.addListener(async () => {
  await ensureDefaults();
  await createContextMenu();
  await restoreCursor();
  await refreshBadge();
  startPolling();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'fetch_image_data_url') {
    fetchImageDataURL(message.url)
      .then((dataUrl) => sendResponse({ ok: true, dataUrl }))
      .catch((error) => sendResponse({ ok: false, error: error instanceof Error ? error.message : String(error) }));
    return true;
  }

  return undefined;
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== CONTEXT_MENU_ID || !tab?.id) {
    return;
  }
  await captureAndSend(tab);
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName !== 'local') {
    return;
  }
  if (changes.bridgePort || changes.gatewayURL || changes.gatewayToken) {
    cursor = '';
    refreshBadge().catch(() => undefined);
    startPolling().catch(() => undefined);
    notifySettingsUpdated().catch(() => undefined);
  }
});

async function ensureDefaults() {
  const current = await chrome.storage.local.get(DEFAULT_SETTINGS);
  const next = {
    bridgePort: normalizePort(current.bridgePort),
    gatewayURL: typeof current.gatewayURL === 'string' ? current.gatewayURL : DEFAULT_SETTINGS.gatewayURL,
    gatewayToken: typeof current.gatewayToken === 'string' ? current.gatewayToken : DEFAULT_SETTINGS.gatewayToken,
  };
  await chrome.storage.local.set(next);
}

async function createContextMenu() {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({
    id: CONTEXT_MENU_ID,
    title: 'Send to Chi',
    contexts: ['page'],
  });
}

async function restoreCursor() {
  const stored = await chrome.storage.local.get({ pollCursor: '' });
  cursor = stored.pollCursor || '';
}

async function saveCursor(value) {
  cursor = value;
  await chrome.storage.local.set({ pollCursor: value });
}

async function getSettings() {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  return {
    bridgePort: normalizePort(settings.bridgePort),
    gatewayURL: typeof settings.gatewayURL === 'string' ? settings.gatewayURL : '',
    gatewayToken: typeof settings.gatewayToken === 'string' ? settings.gatewayToken : '',
  };
}

function normalizePort(value) {
  const port = Number(value);
  return Number.isFinite(port) && port >= 1 && port <= 65535 ? port : DEFAULT_SETTINGS.bridgePort;
}

async function notifySettingsUpdated(extra = {}) {
  const settings = await getSettings();
  chrome.runtime.sendMessage({
    type: 'settings_updated',
    ...settings,
    ...extra,
  }).catch(() => undefined);
}

async function refreshBadge() {
  const { gatewayURL, gatewayToken } = await getSettings();
  const configured = Boolean(gatewayURL && gatewayToken);
  await chrome.action.setBadgeBackgroundColor({ color: configured ? '#0D111B' : '#F26B6B' });
  await chrome.action.setBadgeText({ text: configured ? '' : '!' });
}

function scheduleNextPoll(delayMs = POLL_INTERVAL_MS) {
  if (pollTimer) {
    clearTimeout(pollTimer);
  }
  pollTimer = setTimeout(() => {
    startPolling().catch(() => undefined);
  }, delayMs);
}

async function startPolling() {
  if (pollInFlight) {
    return;
  }
  pollInFlight = true;
  try {
    const { bridgePort } = await getSettings();
    const url = new URL(`http://127.0.0.1:${bridgePort}/v1/poll`);
    if (cursor) {
      url.searchParams.set('since', cursor);
    }

    const response = await fetch(url.toString(), { method: 'GET' });
    if (!response.ok) {
      await notifySettingsUpdated({ bridgeConnected: false, reason: `poll_${response.status}` });
      scheduleNextPoll(POLL_ERROR_BACKOFF_MS);
      return;
    }

    const data = await response.json();
    if (data?.next_cursor != null) {
      await saveCursor(String(data.next_cursor));
    }
    await notifySettingsUpdated({ bridgeConnected: true });

    const events = Array.isArray(data?.events) ? data.events : [];
    for (const event of events) {
      if (event?.type !== 'chrome_capture_request') {
        continue;
      }
      const tab = await getActiveTab();
      if (tab?.id) {
        await captureAndSend(tab);
      }
    }

    scheduleNextPoll(POLL_INTERVAL_MS);
  } catch (error) {
    await notifySettingsUpdated({ bridgeConnected: false, reason: error?.message || 'poll_error' });
    scheduleNextPoll(POLL_ERROR_BACKOFF_MS);
  } finally {
    pollInFlight = false;
  }
}

async function getActiveTab() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  return tabs[0] || null;
}

async function captureAndSend(tab) {
  const { gatewayURL, gatewayToken } = await getSettings();
  if (!tab?.id) {
    return;
  }
  if (!gatewayURL || !gatewayToken) {
    await refreshBadge();
    await notifySettingsUpdated({ gatewayConnected: false, reason: 'missing_gateway_config' });
    return;
  }

  const result = await chrome.tabs.sendMessage(tab.id, { type: 'extract_content' });
  const content = typeof result?.content === 'string' ? result.content : '';
  const meta = result?.meta && typeof result.meta === 'object' ? result.meta : {};
  const imageContext = result?.imageContext && typeof result.imageContext === 'object' ? result.imageContext : null;
  const contentMetrics = result?.contentMetrics && typeof result.contentMetrics === 'object' ? result.contentMetrics : {};
  const url = tab.url || result?.url || '';
  const title = tab.title || result?.title || '';
  const domain = safeHostname(url);

  const payload = {
    entries: [{
      id: makeUUID(),
      url,
      title,
      domain,
      content,
      visitedAt: new Date().toISOString(),
      meta: {
        description: meta.description || '',
        ogTitle: meta.ogTitle || '',
        ogImage: meta.ogImage || '',
        imageContext,
        contentMetrics,
      },
      engagement: {
        activeSeconds: 0,
        scrollDepthPct: 0,
        engaged: false,
      },
      userInitiated: true,
    }],
  };

  const endpoint = new URL('/api/web-history', gatewayURL).toString();
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${gatewayToken}`,
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`Gateway rejected capture (${response.status})`);
  }

  await chrome.action.setBadgeText({ text: '✓' });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' }).catch(() => undefined);
  }, 1000);
  await notifySettingsUpdated({ gatewayConnected: true, lastCaptureURL: url });
}

async function fetchImageDataURL(url) {
  if (!url || !/^https?:/i.test(url)) {
    throw new Error('Unsupported image URL');
  }

  const response = await fetch(url, {
    method: 'GET',
    cache: 'force-cache',
    credentials: 'omit',
  });

  if (!response.ok) {
    throw new Error(`Image fetch failed (${response.status})`);
  }

  const contentType = response.headers.get('content-type') || 'image/png';
  const buffer = await response.arrayBuffer();
  return `data:${contentType};base64,${arrayBufferToBase64(buffer)}`;
}

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = '';
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

function safeHostname(value) {
  try {
    return new URL(value).hostname;
  } catch {
    return '';
  }
}

function makeUUID() {
  if (globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID();
  }
  return `cg-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

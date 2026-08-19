const DEFAULT_SETTINGS = {
  bridgePort: 8765,
  gatewayURL: '',
  gatewayToken: '',
  passiveTracking: true,
  excludedDomains: [],
};

const CONTEXT_MENU_ID = 'clawgate-send-to-chi';
const POLL_INTERVAL_MS = 2500;
const POLL_ERROR_BACKOFF_MS = 5000;
const IMAGE_FETCH_PORT_NAME = 'clawgate_image_fetch';
const OCR_SANDBOX_PATH = 'sandbox/ocr.html';

const PASSIVE_DWELL_MS = 8000;
const PASSIVE_DEDUP_WINDOW_MS = 30 * 60 * 1000;
const PASSIVE_QUEUE_LIMIT = 50;
const PASSIVE_FLUSH_ALARM = 'clawgate-passive-flush';
const PASSIVE_FLUSH_PERIOD_MINUTES = 1.5;
const PASSIVE_SEND_LOG_LIMIT = 200;

// Proposed contract, pending final confirmation with oc-general.cc — see
// docs/plans/delegated-snacking-garden.md "エンドポイント契約". Update this
// path if the agreed contract differs.
const MESSENGER_CAPTURE_ENDPOINT = '/api/messenger-capture';

let cursor = '';
let pollTimer = null;
let pollInFlight = false;

let passiveVisit = null;
const passiveQueue = [];
const passiveSentAtByURL = new Map();

function isMessengerURL(urlString) {
  try {
    const url = new URL(urlString || '');
    if (/(^|\.)messenger\.com$/i.test(url.hostname)) {
      return true;
    }
    if (/(^|\.)facebook\.com$/i.test(url.hostname) && url.pathname.startsWith('/messages')) {
      return true;
    }
  } catch {}
  return false;
}

chrome.runtime.onInstalled.addListener(async () => {
  await ensureDefaults();
  await createContextMenu();
  await restoreCursor();
  await refreshBadge();
  ensurePassiveAlarm().catch(() => undefined);
  armDwellForActiveTab().catch(() => undefined);
  startPolling();
});

chrome.runtime.onStartup.addListener(async () => {
  await ensureDefaults();
  await createContextMenu();
  await restoreCursor();
  await refreshBadge();
  ensurePassiveAlarm().catch(() => undefined);
  armDwellForActiveTab().catch(() => undefined);
  startPolling();
});

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== IMAGE_FETCH_PORT_NAME) {
    return;
  }

  const handlePortMessage = (message) => {
    if (message?.type !== 'fetch_image_data_url') {
      return;
    }

    fetchImageDataURL(message.url)
      .then((dataUrl) => {
        try {
          const sandboxUrl = chrome.runtime.getURL(OCR_SANDBOX_PATH);
          port.postMessage({
            ok: true,
            dataUrl,
            sandboxUrl,
            sandboxOrigin: new URL(sandboxUrl).origin,
          });
        } catch {}
      })
      .catch((error) => {
        try {
          const sandboxUrl = chrome.runtime.getURL(OCR_SANDBOX_PATH);
          port.postMessage({
            ok: false,
            error: error instanceof Error ? error.message : String(error),
            sandboxUrl,
            sandboxOrigin: new URL(sandboxUrl).origin,
          });
        } catch {}
      });
  };

  port.onMessage.addListener(handlePortMessage);
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== CONTEXT_MENU_ID || !tab?.id) {
    return;
  }
  await captureAndSend(tab, { preferredImageURL: typeof info.srcUrl === 'string' ? info.srcUrl : '' });
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    await startPassiveVisit(await chrome.tabs.get(tabId));
  } catch {
    resetPassiveVisit();
  }
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.status !== 'complete' || !tab?.active) {
    return;
  }
  try {
    await startPassiveVisit(tab.id === tabId ? tab : await chrome.tabs.get(tabId));
  } catch {
    resetPassiveVisit();
  }
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== PASSIVE_FLUSH_ALARM) {
    return;
  }
  // Messenger recapture check first, so a freshly-queued entry rides this
  // same flush instead of waiting another 1.5 minutes; this is a backstop for
  // the MutationObserver-driven path (e.g. tab wasn't active when content
  // changed), not the primary trigger.
  handleMessengerFlushAlarmTick()
    .catch(() => undefined)
    .finally(() => {
      flushPassiveQueue().catch(() => undefined);
    });
});

async function handleMessengerFlushAlarmTick() {
  const tab = await getActiveTab();
  if (!tab?.url || !isMessengerURL(tab.url)) {
    return;
  }
  await captureMessengerNow(tab);
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== 'messenger_content_changed' || !sender?.tab?.id) {
    return undefined;
  }
  chrome.tabs.get(sender.tab.id)
    .then((tab) => captureMessengerNow(tab))
    .catch(() => undefined);
  return undefined;
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
  if (changes.passiveTracking) {
    if (changes.passiveTracking.newValue) {
      armDwellForActiveTab().catch(() => undefined);
    } else {
      resetPassiveVisit();
      passiveQueue.length = 0;
    }
  }
  if (changes.excludedDomains) {
    const excludedDomains = normalizeExcludedDomains(changes.excludedDomains.newValue);
    if (excludedDomains.length) {
      for (let i = passiveQueue.length - 1; i >= 0; i -= 1) {
        if (isExcludedHostname(passiveQueue[i]?.domain, excludedDomains)) {
          passiveQueue.splice(i, 1);
        }
      }
    }
  }
});

async function ensureDefaults() {
  const current = await chrome.storage.local.get(DEFAULT_SETTINGS);
  const next = {
    bridgePort: normalizePort(current.bridgePort),
    gatewayURL: typeof current.gatewayURL === 'string' ? current.gatewayURL : DEFAULT_SETTINGS.gatewayURL,
    gatewayToken: typeof current.gatewayToken === 'string' ? current.gatewayToken : DEFAULT_SETTINGS.gatewayToken,
    passiveTracking: typeof current.passiveTracking === 'boolean' ? current.passiveTracking : DEFAULT_SETTINGS.passiveTracking,
    excludedDomains: normalizeExcludedDomains(current.excludedDomains),
  };
  await chrome.storage.local.set(next);
}

async function createContextMenu() {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create(
    {
      id: CONTEXT_MENU_ID,
      title: 'Send to Chi',
      contexts: ['page', 'image'],
    },
    () => {
      void chrome.runtime.lastError;
    },
  );
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
    passiveTracking: typeof settings.passiveTracking === 'boolean' ? settings.passiveTracking : DEFAULT_SETTINGS.passiveTracking,
    excludedDomains: normalizeExcludedDomains(settings.excludedDomains),
  };
}

function normalizePort(value) {
  const port = Number(value);
  return Number.isFinite(port) && port >= 1 && port <= 65535 ? port : DEFAULT_SETTINGS.bridgePort;
}

function normalizeExcludedDomains(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  const seen = new Set();
  for (const item of value) {
    if (typeof item !== 'string') {
      continue;
    }
    const domain = item.trim().toLowerCase();
    if (domain) {
      seen.add(domain);
    }
  }
  return Array.from(seen);
}

function hostnameMatchesDomain(hostname, domain) {
  const host = (hostname || '').toLowerCase();
  const target = (domain || '').toLowerCase();
  if (!host || !target) {
    return false;
  }
  return host === target || host.endsWith(`.${target}`);
}

function isExcludedHostname(hostname, excludedDomains) {
  if (!Array.isArray(excludedDomains) || !excludedDomains.length) {
    return false;
  }
  return excludedDomains.some((domain) => hostnameMatchesDomain(hostname, domain));
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

async function ensurePassiveAlarm() {
  await chrome.alarms.create(PASSIVE_FLUSH_ALARM, {
    periodInMinutes: PASSIVE_FLUSH_PERIOD_MINUTES,
  });
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

async function ensureContentScript(tabId) {
  try {
    const response = await chrome.tabs.sendMessage(tabId, { type: 'ping' });
    if (response?.ok) {
      return;
    }
  } catch {
    // No content script reachable in this context -> inject below.
  }
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ['content.js'],
  });
}

async function captureAndSend(tab, options = {}) {
  const { gatewayURL, gatewayToken } = await getSettings();
  if (!tab?.id) {
    return;
  }
  if (!gatewayURL || !gatewayToken) {
    await refreshBadge();
    await notifySettingsUpdated({ gatewayConnected: false, reason: 'missing_gateway_config' });
    return;
  }

  await ensureContentScript(tab.id);

  const result = await chrome.tabs.sendMessage(tab.id, {
    type: 'extract_content',
    preferredImageURL: typeof options.preferredImageURL === 'string' ? options.preferredImageURL : '',
  });
  const content = typeof result?.content === 'string' ? result.content : '';
  const meta = result?.meta && typeof result.meta === 'object' ? result.meta : {};
  const imageContext = result?.imageContext && typeof result.imageContext === 'object' ? result.imageContext : null;
  const contentMetrics = result?.contentMetrics && typeof result.contentMetrics === 'object' ? result.contentMetrics : {};
  const url = tab.url || result?.url || '';
  const title = tab.title || result?.title || '';
  const domain = safeHostname(url);

  const entries = [{
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
  }];

  await postWebHistoryEntries(entries, { gatewayURL, gatewayToken });

  await appendPassiveSendLog([{
    domain: domain || '',
    title: title || '',
    url: url || '',
    sentAt: new Date().toISOString(),
    manual: true,
  }]);

  await chrome.action.setBadgeText({ text: '✓' });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' }).catch(() => undefined);
  }, 1000);
  await notifySettingsUpdated({ gatewayConnected: true, lastCaptureURL: url });
}

async function armDwellForActiveTab() {
  const tab = await getActiveTab();
  await startPassiveVisit(tab);
}

async function startPassiveVisit(tab) {
  resetPassiveVisit();

  const settings = await getSettings();
  if (!settings.passiveTracking || !isPassiveEligibleURL(tab?.url, settings.gatewayURL, settings.excludedDomains)) {
    return;
  }

  const visit = {
    tabId: tab.id,
    url: tab.url,
    startedAt: Date.now(),
    timerId: null,
  };
  // Messenger favors capturing as much as possible over the generic dwell
  // throttle — skip the wait so the first capture happens right away.
  const dwellMs = isMessengerURL(tab.url) ? 0 : PASSIVE_DWELL_MS;
  visit.timerId = setTimeout(() => {
    handlePassiveDwell(visit).catch(() => undefined);
  }, dwellMs);
  passiveVisit = visit;
}

function resetPassiveVisit() {
  if (passiveVisit?.timerId) {
    clearTimeout(passiveVisit.timerId);
  }
  passiveVisit = null;
}

async function handlePassiveDwell(visit) {
  if (passiveVisit !== visit) {
    return;
  }
  passiveVisit = null;

  const settings = await getSettings();
  if (!settings.passiveTracking || !settings.gatewayURL || !settings.gatewayToken) {
    return;
  }

  let tab;
  try {
    tab = await chrome.tabs.get(visit.tabId);
  } catch {
    return;
  }

  if (!tab?.active || tab.url !== visit.url || !isPassiveEligibleURL(tab.url, settings.gatewayURL, settings.excludedDomains)) {
    return;
  }

  if (isMessengerURL(tab.url)) {
    await captureMessengerNow(tab);
    return;
  }

  if (isPassiveDuplicate(tab.url)) {
    return;
  }

  const activeSeconds = Math.max(0, Math.round((Date.now() - visit.startedAt) / 1000));
  const entry = await buildPassiveEntry(tab, activeSeconds);
  if (!entry) {
    return;
  }

  passiveSentAtByURL.set(entry.url, { time: Date.now() });
  enqueuePassiveEntry(entry);
}

// Messenger favors "capture as much as possible" over the generic dwell/
// alarm-cadence throttle. Called both from the (zero-wait) dwell path and
// from the MutationObserver notification in content.js, and flushes
// immediately rather than waiting for the next periodic alarm.
async function captureMessengerNow(tab) {
  const settings = await getSettings();
  if (!settings.passiveTracking || !settings.gatewayURL || !settings.gatewayToken) {
    return;
  }
  if (!tab?.url || !isMessengerURL(tab.url) || !isPassiveEligibleURL(tab.url, settings.gatewayURL, settings.excludedDomains)) {
    return;
  }

  const entry = await buildMessengerEntry(tab);
  if (!entry) {
    return;
  }
  if (isPassiveDuplicate(entry.threadUrl, entry.contentSignature)) {
    return;
  }

  passiveSentAtByURL.set(entry.threadUrl, { time: Date.now(), signature: entry.contentSignature });
  enqueuePassiveEntry(entry);
  await flushPassiveQueue();
}

async function buildPassiveEntry(tab, activeSeconds) {
  try {
    await ensureContentScript(tab.id);

    const result = await chrome.tabs.sendMessage(tab.id, {
      type: 'extract_content',
      preferredImageURL: '',
    });
    const content = typeof result?.content === 'string' ? result.content : '';
    const meta = result?.meta && typeof result.meta === 'object' ? result.meta : {};
    const imageContext = result?.imageContext && typeof result.imageContext === 'object' ? result.imageContext : null;
    const contentMetrics = result?.contentMetrics && typeof result.contentMetrics === 'object' ? result.contentMetrics : {};
    const url = tab.url || result?.url || '';
    const title = tab.title || result?.title || '';

    return {
      id: makeUUID(),
      url,
      title,
      domain: safeHostname(url),
      content,
      visitedAt: new Date().toISOString(),
      dwellSeconds: activeSeconds,
      meta: {
        description: meta.description || '',
        ogTitle: meta.ogTitle || '',
        ogImage: meta.ogImage || '',
        imageContext,
        contentMetrics,
        source: 'passive',
      },
      engagement: {
        activeSeconds,
        scrollDepthPct: 0,
        engaged: true,
      },
      userInitiated: false,
    };
  } catch {
    return null;
  }
}

function hashString(value) {
  let hash = 0;
  for (let i = 0; i < value.length; i += 1) {
    hash = (hash * 31 + value.charCodeAt(i)) | 0;
  }
  return (hash >>> 0).toString(36);
}

// Builds a messenger-capture entry per the oc-general.cc contract (proposed,
// pending final confirmation — see MESSENGER_CAPTURE_ENDPOINT above): a
// stable per-thread id (so recaptures are updates, not new rows), a
// structured messages[] array (never a flattened blob), explicit
// captureScope/oldestCapturedAt so downstream can tell "no reply" from "reply
// not captured", and ISO-8601 timestamps with an explicit UTC offset.
async function buildMessengerEntry(tab) {
  try {
    await ensureContentScript(tab.id);

    const result = await chrome.tabs.sendMessage(tab.id, {
      type: 'extract_content',
      preferredImageURL: '',
    });
    const messenger = result?.messenger;
    if (!messenger || !Array.isArray(messenger.messages) || !messenger.messages.length) {
      return null;
    }

    const url = tab.url || result?.url || '';
    const threadId = typeof messenger.threadId === 'string' && messenger.threadId ? messenger.threadId : hashString(url);

    return {
      id: `messenger:${threadId}`,
      platform: 'messenger',
      threadUrl: url,
      contactName: typeof messenger.contactName === 'string' ? messenger.contactName : '',
      capturedAt: new Date().toISOString(),
      captureScope: messenger.captureScope === 'full_thread' ? 'full_thread' : 'visible_window',
      oldestCapturedAt: typeof messenger.oldestCapturedAt === 'string' ? messenger.oldestCapturedAt : new Date().toISOString(),
      messageCount: Number.isFinite(messenger.messageCount) ? messenger.messageCount : messenger.messages.length,
      contentSignature: typeof messenger.contentSignature === 'string' ? messenger.contentSignature : '',
      messages: messenger.messages.map((m) => ({
        sender: typeof m.sender === 'string' ? m.sender : '',
        fromSelf: typeof m.fromSelf === 'boolean' ? m.fromSelf : null,
        text: typeof m.text === 'string' ? m.text : '',
        sentAt: typeof m.sentAt === 'string' ? m.sentAt : new Date().toISOString(),
        sentAtPrecision: m.sentAtPrecision === 'exact' ? 'exact' : 'approximate',
      })),
    };
  } catch {
    return null;
  }
}

function enqueuePassiveEntry(entry) {
  passiveQueue.push(entry);
  while (passiveQueue.length > PASSIVE_QUEUE_LIMIT) {
    passiveQueue.shift();
  }
}

async function flushPassiveQueue() {
  if (!passiveQueue.length) {
    return;
  }

  const settings = await getSettings();
  if (!settings.passiveTracking || !settings.gatewayURL || !settings.gatewayToken) {
    return;
  }

  const entries = passiveQueue.slice();
  passiveQueue.splice(0, entries.length);

  const messengerEntries = entries.filter((entry) => entry.platform === 'messenger');
  const webEntries = entries.filter((entry) => entry.platform !== 'messenger');

  const sentAt = new Date().toISOString();

  if (webEntries.length) {
    await postWebHistoryEntries(webEntries, settings);
    await appendPassiveSendLog(webEntries.map((entry) => ({
      domain: entry.domain || '',
      title: entry.title || '',
      url: entry.url || '',
      sentAt,
    })));
  }

  if (messengerEntries.length) {
    await postMessengerEntries(messengerEntries, settings);
    await appendPassiveSendLog(messengerEntries.map((entry) => ({
      domain: safeHostname(entry.threadUrl) || '',
      title: entry.contactName || '',
      url: entry.threadUrl || '',
      sentAt,
    })));
  }
}

async function appendPassiveSendLog(records) {
  if (!Array.isArray(records) || !records.length) {
    return;
  }
  const stored = await chrome.storage.local.get({ passiveSendLog: [] });
  const log = Array.isArray(stored.passiveSendLog) ? stored.passiveSendLog : [];
  log.push(...records);
  const capped = log.length > PASSIVE_SEND_LOG_LIMIT
    ? log.slice(log.length - PASSIVE_SEND_LOG_LIMIT)
    : log;
  await chrome.storage.local.set({ passiveSendLog: capped });
}

async function postWebHistoryEntries(entries, settings) {
  const endpoint = new URL('/api/web-history', settings.gatewayURL).toString();
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${settings.gatewayToken}`,
    },
    body: JSON.stringify({ entries }),
  });

  if (!response.ok) {
    throw new Error(`Gateway rejected capture (${response.status})`);
  }
  return response;
}

async function postMessengerEntries(entries, settings) {
  const endpoint = new URL(MESSENGER_CAPTURE_ENDPOINT, settings.gatewayURL).toString();
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${settings.gatewayToken}`,
    },
    body: JSON.stringify({ entries }),
  });

  if (!response.ok) {
    throw new Error(`Gateway rejected messenger capture (${response.status})`);
  }
  return response;
}

// `signature`, when provided (messenger only), makes this a content-change
// check instead of a time-window throttle: a thread whose captured content
// hasn't changed since the last send is a duplicate regardless of elapsed
// time, but a genuinely new/changed capture is never held back by the window.
function isPassiveDuplicate(url, signature) {
  const previous = passiveSentAtByURL.get(url);
  if (!previous) {
    return false;
  }
  if (signature != null) {
    return previous.signature === signature;
  }
  return Date.now() - previous.time < PASSIVE_DEDUP_WINDOW_MS;
}

function isPassiveEligibleURL(value, gatewayURL, excludedDomains) {
  let url;
  try {
    url = new URL(value || '');
  } catch {
    return false;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return false;
  }
  if (url.hostname === 'localhost' || url.hostname === '127.0.0.1') {
    return false;
  }
  if (isExcludedHostname(url.hostname, excludedDomains)) {
    return false;
  }
  const gatewayHost = safeHostname(gatewayURL);
  return !gatewayHost || url.hostname !== gatewayHost;
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

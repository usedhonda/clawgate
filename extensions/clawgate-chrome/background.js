const DEFAULT_SETTINGS = {
  port: 8765,
  pairingToken: "",
};

const CONTEXT_MENU_ID = "clawgate-send-to-chi";
const POLL_INTERVAL_MS = 2500;
const POLL_ERROR_BACKOFF_MS = 5000;

let cursor = "";
let pollTimer = null;
let pollInFlight = false;

chrome.runtime.onInstalled.addListener(async () => {
  const current = await chrome.storage.local.get(DEFAULT_SETTINGS);
  const next = {
    port: Number.isFinite(Number(current.port)) ? Number(current.port) : DEFAULT_SETTINGS.port,
    pairingToken: typeof current.pairingToken === "string" ? current.pairingToken : DEFAULT_SETTINGS.pairingToken,
  };
  await chrome.storage.local.set(next);
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: CONTEXT_MENU_ID,
      title: "Send to Chi",
      contexts: ["page"],
    });
  });
  startPolling();
});

chrome.runtime.onStartup.addListener(() => {
  startPolling();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== CONTEXT_MENU_ID || !tab?.id) return;
  await captureAndSend(tab);
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName !== "local") return;
  if (changes.port || changes.pairingToken) {
    cursor = "";
    startPolling();
  }
});

async function getSettings() {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  return {
    port: Number.isFinite(Number(settings.port)) ? Number(settings.port) : DEFAULT_SETTINGS.port,
    pairingToken: typeof settings.pairingToken === "string" ? settings.pairingToken : DEFAULT_SETTINGS.pairingToken,
  };
}

function notifySettingsUpdated(payload = {}) {
  chrome.runtime.sendMessage({ type: "settings_updated", ...payload }).catch(() => undefined);
}

function scheduleNextPoll(delayMs = POLL_INTERVAL_MS) {
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = setTimeout(() => {
    startPolling().catch(() => undefined);
  }, delayMs);
}

async function startPolling() {
  if (pollInFlight) return;
  pollInFlight = true;
  try {
    const { port, pairingToken } = await getSettings();
    if (!pairingToken) {
      notifySettingsUpdated({ connected: false, reason: "missing_token" });
      scheduleNextPoll(POLL_INTERVAL_MS);
      return;
    }

    const url = new URL(`http://127.0.0.1:${port}/v1/poll`);
    if (cursor) url.searchParams.set("since", cursor);

    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        "X-ClawGate-Token": pairingToken,
      },
    });

    if (!response.ok) {
      notifySettingsUpdated({ connected: false, reason: `poll_${response.status}` });
      scheduleNextPoll(POLL_ERROR_BACKOFF_MS);
      return;
    }

    const data = await response.json();
    if (data?.next_cursor != null) cursor = String(data.next_cursor);
    notifySettingsUpdated({ connected: true, cursor });

    const events = Array.isArray(data?.events) ? data.events : [];
    for (const event of events) {
      if (event?.type !== "chrome_capture_request") continue;
      const tab = await getActiveTab();
      if (tab?.id) {
        await captureAndSend(tab);
      }
    }

    scheduleNextPoll(POLL_INTERVAL_MS);
  } catch (error) {
    notifySettingsUpdated({ connected: false, reason: error?.message || "poll_error" });
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
  const { port, pairingToken } = await getSettings();
  if (!tab?.id) return;

  const result = await chrome.tabs.sendMessage(tab.id, { type: "extract_content" });
  const payload = {
    url: tab.url || "",
    title: tab.title || "",
    content: result?.text || "",
  };

  await fetch(`http://127.0.0.1:${port}/v1/chrome/page-capture`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-ClawGate-Token": pairingToken,
    },
    body: JSON.stringify(payload),
  });

  await chrome.action.setBadgeText({ text: "✓" });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: "" }).catch(() => undefined);
  }, 1000);
}

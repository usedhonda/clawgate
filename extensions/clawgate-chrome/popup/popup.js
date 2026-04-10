const DEFAULT_SETTINGS = {
  bridgePort: 8765,
  gatewayURL: '',
  gatewayToken: '',
};

const statusDot = document.getElementById('status-dot');
const statusText = document.getElementById('status-text');
const gatewayURLInput = document.getElementById('gateway-url');
const gatewayTokenInput = document.getElementById('gateway-token');
const connectButton = document.getElementById('connect-button');
const testButton = document.getElementById('test-button');

init().catch((error) => {
  setStatus(false, error?.message || 'Disconnected');
});

async function init() {
  await syncFromStorage();
  connectButton.addEventListener('click', connectToClawGate);
  testButton.addEventListener('click', testConnection);

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== 'settings_updated') {
      return;
    }
    applySettings(message);
  });

  await testConnection();
}

async function syncFromStorage() {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  applySettings(settings);
}

function applySettings(settings) {
  const gatewayURL = typeof settings.gatewayURL === 'string' ? settings.gatewayURL : '';
  const gatewayToken = typeof settings.gatewayToken === 'string' ? settings.gatewayToken : '';

  gatewayURLInput.value = gatewayURL;
  gatewayTokenInput.value = maskToken(gatewayToken);
  connectButton.textContent = gatewayURL && gatewayToken ? 'Reconnect to ClawGate' : 'Connect to ClawGate';
}

async function connectToClawGate() {
  const { bridgePort } = await chrome.storage.local.get(DEFAULT_SETTINGS);
  const port = normalizePort(bridgePort);
  setStatus(false, 'Connecting...');

  try {
    const response = await fetch(`http://127.0.0.1:${port}/v1/openclaw-info`);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const data = await response.json();
    const host = typeof data.gateway_host === 'string' && data.gateway_host
      ? data.gateway_host
      : (typeof data.host === 'string' ? data.host : '');
    const gatewayPort = Number(data.port);
    const token = typeof data.token === 'string' ? data.token : '';
    if (!host || !Number.isFinite(gatewayPort) || !token) {
      throw new Error('Incomplete bootstrap payload');
    }

    const gatewayURL = `http://${host}:${gatewayPort}`;
    await chrome.storage.local.set({
      bridgePort: port,
      gatewayURL,
      gatewayToken: token,
    });
    applySettings({ gatewayURL, gatewayToken: token });
    await chrome.action.setBadgeText({ text: '' });
    chrome.runtime.sendMessage({ type: 'settings_updated', gatewayURL, gatewayToken: token }).catch(() => undefined);
    await testConnection();
  } catch (error) {
    setStatus(false, error?.message || 'Connect failed');
  }
}

async function testConnection() {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  const gatewayURL = typeof settings.gatewayURL === 'string' ? settings.gatewayURL : '';
  const gatewayToken = typeof settings.gatewayToken === 'string' ? settings.gatewayToken : '';

  if (!gatewayURL || !gatewayToken) {
    setStatus(false, 'Disconnected');
    return;
  }

  try {
    const response = await fetch(new URL('/health', gatewayURL).toString(), {
      headers: {
        Authorization: `Bearer ${gatewayToken}`,
      },
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    setStatus(true, 'Connected');
  } catch {
    setStatus(false, 'Disconnected');
  }
}

function setStatus(connected, text) {
  statusDot.classList.toggle('status-online', connected);
  statusDot.classList.toggle('status-offline', !connected);
  statusText.textContent = text;
}

function normalizePort(value) {
  const port = Number(value);
  return Number.isFinite(port) && port >= 1 && port <= 65535 ? port : DEFAULT_SETTINGS.bridgePort;
}

function maskToken(token) {
  if (!token) {
    return '';
  }
  if (token.length <= 8) {
    return '•'.repeat(token.length);
  }
  return `${token.slice(0, 4)}${'•'.repeat(Math.max(4, token.length - 8))}${token.slice(-4)}`;
}

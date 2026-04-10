const DEFAULT_SETTINGS = {
  port: 8765,
  pairingToken: "",
};

const statusDot = document.getElementById("status-dot");
const statusText = document.getElementById("status-text");
const portInput = document.getElementById("port-input");
const tokenInput = document.getElementById("token-input");
const testButton = document.getElementById("test-button");

init().catch((error) => {
  setStatus(false, error?.message || "Disconnected");
});

async function init() {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  portInput.value = String(Number(settings.port) || DEFAULT_SETTINGS.port);
  // Show masked token if one is already stored
  tokenInput.value = maskToken(settings.pairingToken || "");
  tokenInput.dataset.stored = settings.pairingToken || "";

  portInput.addEventListener("change", savePort);

  // Save token when user finishes editing
  tokenInput.addEventListener("focus", () => {
    // Clear masked display so user can type/paste plaintext
    if (tokenInput.value === maskToken(tokenInput.dataset.stored || "")) {
      tokenInput.value = "";
    }
  });
  tokenInput.addEventListener("blur", saveToken);
  tokenInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      tokenInput.blur();
    }
  });

  testButton.addEventListener("click", testConnection);

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== "settings_updated") return;
    if (typeof message.connected === "boolean") {
      setStatus(message.connected, message.connected ? "Connected" : "Disconnected");
    }
  });

  await testConnection();
}

async function savePort() {
  const port = Number(portInput.value);
  if (!Number.isFinite(port) || port < 1 || port > 65535) {
    portInput.value = String(DEFAULT_SETTINGS.port);
    return;
  }
  await chrome.storage.local.set({ port });
}

async function saveToken() {
  const raw = tokenInput.value.trim();
  // If the field still shows the masked version, don't overwrite
  if (raw === maskToken(tokenInput.dataset.stored || "")) return;
  const token = raw;
  tokenInput.dataset.stored = token;
  tokenInput.value = maskToken(token);
  await chrome.storage.local.set({ pairingToken: token });
  // Trigger reconnect
  chrome.runtime.sendMessage({ type: "settings_updated" }).catch(() => undefined);
  await testConnection();
}

async function testConnection() {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  const port = Number(settings.port) || DEFAULT_SETTINGS.port;

  try {
    const response = await fetch(`http://127.0.0.1:${port}/v1/health`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    const connected = Boolean(data?.ok);
    setStatus(connected, connected ? "Connected" : "Disconnected");
    chrome.runtime.sendMessage({ type: "settings_updated", connected }).catch(() => undefined);
  } catch {
    setStatus(false, "Disconnected");
    chrome.runtime.sendMessage({ type: "settings_updated", connected: false }).catch(() => undefined);
  }
}

function setStatus(connected, text) {
  statusDot.classList.toggle("status-online", connected);
  statusDot.classList.toggle("status-offline", !connected);
  statusText.textContent = text;
}

function maskToken(token) {
  if (!token) return "";
  if (token.length <= 8) return "•".repeat(token.length);
  return `${token.slice(0, 4)}${"•".repeat(Math.max(4, token.length - 8))}${token.slice(-4)}`;
}

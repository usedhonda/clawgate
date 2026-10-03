// Independent durable mirror. Existing web-history and Messenger delivery
// remains authoritative until the personal hub route is accepted per domain.
const KEY = 'personalHubOutbox';
const RECEIPT_KEY = 'lastPersonalHubReceipt';
const DIRECT_SELECTED_KEY = 'personalHubDirectSelected';
const ENDPOINT = '/api/personal-hub/chrome';
const DEFAULT_TIMEOUT_MS = 10_000;
const storageSequences = new WeakMap();
const flushFlights = new WeakMap();

function exclusive(storage, work) {
  const sequence = storageSequences.get(storage) || Promise.resolve();
  const result = sequence.then(work);
  storageSequences.set(storage, result.catch(() => undefined));
  return result;
}

function clone(value) {
  if (typeof structuredClone === 'function') return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

function canonicalRecord(value) {
  return JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item)
    ? Object.fromEntries(Object.keys(item).sort().map((key) => [key, item[key]])) : item);
}

function sameRecord(left, right) { return canonicalRecord(left) === canonicalRecord(right); }

async function readQueue(storage) {
  const stored = await storage.get({ [KEY]: [] });
  return Array.isArray(stored[KEY]) ? stored[KEY] : [];
}

function timeoutFor(settings) {
  return Number.isFinite(settings?.timeoutMs) && settings.timeoutMs > 0 ? settings.timeoutMs : DEFAULT_TIMEOUT_MS;
}

function personalHubDestination(settings) {
  const rawURL = settings?.personalHubURL;
  const configured = rawURL !== undefined && rawURL !== null && String(rawURL).trim() !== '';
  if (!configured) return null;
  if (typeof settings.personalHubToken !== 'string' || !settings.personalHubToken.trim()) return false;
  try {
    const url = new URL(String(rawURL));
    const hostname = url.hostname.toLowerCase();
    const loopback = hostname === '127.0.0.1' || hostname === '::1' || hostname === '[::1]';
    if (!url.hostname || url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
        (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback))) return false;
    return { url: new URL('/v1/events', url).toString(), token: settings.personalHubToken, personal: true };
  } catch { return false; }
}

function compactReceipt(receipt) {
  return {
    receipt_version: receipt.receipt_version,
    source: receipt.source,
    external_id: receipt.external_id,
    event_id: receipt.event_id,
    sha256: null,
    byte_length: 0,
    ingest_sequence: receipt.ingest_sequence,
  };
}

function validPersonalReceipt(receipt, event) {
  return receipt && receipt.receipt_version === 1 && receipt.source === 'chrome' &&
    receipt.external_id === event.external_id && typeof receipt.event_id === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(receipt.event_id) && receipt.sha256 === null &&
    receipt.byte_length === 0 && Number.isSafeInteger(receipt.ingest_sequence) && receipt.ingest_sequence > 0;
}

async function postWithTimeout(url, options, post, timeoutMs) {
  const controller = typeof AbortController === 'function' ? new AbortController() : null;
  const request = { ...options, ...(controller ? { signal: controller.signal } : {}) };
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(async () => {
        const response = await post(url, request);
        // A conflict may have no JSON body; it must not starve later records.
        return { response, result: response.ok ? await response.json() : null };
      }),
      new Promise((_, reject) => { timer = setTimeout(() => { controller?.abort(); reject(new Error('hub outbox request timeout')); }, timeoutMs); }),
    ]);
  } finally { clearTimeout(timer); }
}

export function hubEventForEntry(entry) {
  if (!entry || typeof entry.id !== 'string' || !entry.id) return null;
  const messenger = entry.platform === 'messenger';
  const selected = !messenger && entry.userInitiated === true;
  const occurredAt = messenger ? entry.capturedAt : entry.visitedAt;
  if (typeof occurredAt !== 'string' || !Number.isFinite(Date.parse(occurredAt))) return null;
  return {
    source: 'chrome',
    domain: messenger ? 'messenger' : selected ? 'page' : 'history',
    kind: messenger ? 'visible-window' : selected ? 'selected-page' : 'visit',
    occurred_at: occurredAt,
    external_id: `chrome:${entry.id}`,
    identity: null,
    metadata: { capture_scope: messenger ? 'visible_window' : selected ? 'explicit_selected_page' : 'passive_visit',
      entry },
  };
}

export async function enqueueHubEntry(entry, storage = chrome.storage.local) {
  const event = clone(hubEventForEntry(entry));
  if (!event) return false;
  return exclusive(storage, async () => {
    const queue = await readQueue(storage);
    const existing = queue.find((item) => item?.external_id === event.external_id);
    if (existing) return sameRecord(existing, event);
    await storage.set({ [KEY]: [...queue, event] });
    return true;
  });
}

export async function flushHubOutbox(settings, storage = chrome.storage.local, post = fetch) {
  const personal = personalHubDestination(settings);
  // Once provisioned, missing settings are an outage, never legacy fallback.
  const directSelected = await exclusive(storage, async () => {
    const previous = await storage.get({ [DIRECT_SELECTED_KEY]: false });
    if (personal !== null && previous[DIRECT_SELECTED_KEY] !== true) {
      await storage.set({ [DIRECT_SELECTED_KEY]: true });
    }
    return personal !== null || previous[DIRECT_SELECTED_KEY] === true;
  });
  let destination;
  if (personal === false || (!personal && directSelected)) {
    const queue = await exclusive(storage, () => readQueue(storage));
    return { pending: queue.length, acked: 0 };
  }
  if (personal) destination = personal;
  else if (settings?.gatewayURL && settings?.gatewayToken) {
    destination = { url: new URL(ENDPOINT, settings.gatewayURL).toString(), token: settings.gatewayToken, personal: false };
  } else return { pending: null, acked: 0 };
  const active = flushFlights.get(storage);
  if (active) return active;
  const flight = (async () => {
    const queue = await exclusive(storage, () => readQueue(storage));
    if (!queue.length) return { pending: 0, acked: 0 };
    const snapshot = queue.map((event) => clone(event));
    const acknowledged = [];
    let latestReceipt = null;
    let blocked = false;
    for (const event of snapshot) {
      if (blocked) break;
      try {
        const result = await postWithTimeout(destination.url, {
          method: 'POST', redirect: 'error',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${destination.token}` },
          body: JSON.stringify(event),
        }, post, timeoutFor(settings));
        if (result.response?.status === 409) continue;
        if (!result.response?.ok) { blocked = true; continue; }
        if (destination.personal && ![200, 201].includes(result.response.status)) { blocked = true; continue; }
        if (destination.personal) {
          if (validPersonalReceipt(result.result?.storage_receipt, event)) {
            acknowledged.push(event);
            latestReceipt = compactReceipt(result.result.storage_receipt);
          } else blocked = true;
        } else if (result.result?.ok === true && result.result.externalId === event.external_id &&
                   ['created', 'duplicate'].includes(result.result.status)) {
          acknowledged.push(event);
        } else {
          blocked = true;
        }
      } catch {
        blocked = true;
      }
    }
    return exclusive(storage, async () => {
      const current = await readQueue(storage);
      let remaining = current;
      let acked = 0;
      if (acknowledged.length) {
        remaining = [...current];
        for (const event of acknowledged) {
          const index = remaining.findIndex((item) => sameRecord(item, event));
          if (index >= 0) { remaining.splice(index, 1); acked += 1; }
        }
        if (acked) {
          const writes = { [KEY]: remaining };
          if (latestReceipt) writes[RECEIPT_KEY] = latestReceipt;
          await storage.set(writes);
        }
      }
      return { pending: remaining.length, acked };
    });
  })();
  flushFlights.set(storage, flight);
  flight.then(
    () => { if (flushFlights.get(storage) === flight) flushFlights.delete(storage); },
    () => { if (flushFlights.get(storage) === flight) flushFlights.delete(storage); },
  );
  return flight;
}

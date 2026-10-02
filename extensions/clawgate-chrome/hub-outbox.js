// Independent durable mirror. Existing web-history and Messenger delivery
// remains authoritative until the personal hub route is accepted per domain.
const KEY = 'personalHubOutbox';
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
  if (!settings?.gatewayURL || !settings?.gatewayToken) return { pending: null, acked: 0 };
  const active = flushFlights.get(storage);
  if (active) return active;
  const flight = (async () => {
    const queue = await exclusive(storage, () => readQueue(storage));
    if (!queue.length) return { pending: 0, acked: 0 };
    const snapshot = queue.map((event) => clone(event));
    const acknowledged = [];
    let blocked = false;
    for (const event of snapshot) {
      if (blocked) break;
      try {
        const result = await postWithTimeout(new URL(ENDPOINT, settings.gatewayURL).toString(), {
          method: 'POST', redirect: 'error',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${settings.gatewayToken}` },
          body: JSON.stringify(event),
        }, post, timeoutFor(settings));
        if (result.response?.status === 409) continue;
        if (!result.response?.ok) { blocked = true; continue; }
        if (result.result?.ok === true && result.result.externalId === event.external_id &&
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
        if (acked) await storage.set({ [KEY]: remaining });
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

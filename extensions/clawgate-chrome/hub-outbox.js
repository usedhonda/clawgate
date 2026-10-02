// Independent durable mirror. Existing web-history and Messenger delivery
// remains authoritative until the personal hub route is accepted per domain.
const KEY = 'personalHubOutbox';
const ENDPOINT = '/api/personal-hub/chrome';
let sequence = Promise.resolve();

function exclusive(work) {
  const result = sequence.then(work);
  sequence = result.catch(() => undefined);
  return result;
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
  const event = hubEventForEntry(entry);
  if (!event) return false;
  return exclusive(async () => {
    const stored = await storage.get({ [KEY]: [] });
    const queue = Array.isArray(stored[KEY]) ? stored[KEY] : [];
    if (queue.some((item) => item?.external_id === event.external_id)) return true;
    await storage.set({ [KEY]: [...queue, event] });
    return true;
  });
}

export async function flushHubOutbox(settings, storage = chrome.storage.local, post = fetch) {
  if (!settings?.gatewayURL || !settings?.gatewayToken) return { pending: null, acked: 0 };
  return exclusive(async () => {
    const stored = await storage.get({ [KEY]: [] });
    const queue = Array.isArray(stored[KEY]) ? stored[KEY] : [];
    if (!queue.length) return { pending: 0, acked: 0 };
    const remaining = [];
    let acked = 0;
    let blocked = false;
    for (const event of queue) {
      if (blocked) { remaining.push(event); continue; }
      try {
        const response = await post(new URL(ENDPOINT, settings.gatewayURL).toString(), {
          method: 'POST', redirect: 'error',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${settings.gatewayToken}` },
          body: JSON.stringify(event),
        });
        if (response.status === 409) { remaining.push(event); continue; }
        if (!response.ok) { blocked = true; remaining.push(event); continue; }
        const result = await response.json();
        if (result?.ok === true && result.externalId === event.external_id &&
            ['created', 'duplicate'].includes(result.status)) {
          acked += 1;
        } else {
          blocked = true;
          remaining.push(event);
        }
      } catch {
        blocked = true;
        remaining.push(event);
      }
    }
    if (acked) await storage.set({ [KEY]: remaining });
    return { pending: remaining.length, acked };
  });
}

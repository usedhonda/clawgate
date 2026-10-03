const MAX_PROVISION_BYTES = 64 * 1024;
const MAX_EVENT_BYTES = 20 * 1024 * 1024;
const MAX_CHUNK_BYTES = 4 * 1024 * 1024;
const SOURCE = 'chrome';
const ALLOWED_DOMAINS = Object.freeze(['page', 'history', 'messenger']);

function invalid(message) {
  return { ok: false, error: message };
}

function exactDomains(value) {
  return Array.isArray(value) && value.length === ALLOWED_DOMAINS.length &&
    value.every((item) => typeof item === 'string') && new Set(value).size === ALLOWED_DOMAINS.length &&
    ALLOWED_DOMAINS.every((item) => value.includes(item));
}

function validateBaseURL(value) {
  if (typeof value !== 'string' || !value || /\s/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && Boolean(url.hostname) && !url.username && !url.password &&
      (url.pathname === '' || url.pathname === '/') && !url.search && !url.hash;
  } catch {
    return false;
  }
}

export function validateProvision(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return invalid('provision_invalid');
  if (value.schema_version !== 1 || value.source !== SOURCE || !exactDomains(value.allowed_domains)) {
    return invalid('provision_contract_invalid');
  }
  if (!validateBaseURL(value.base_url)) return invalid('provision_url_invalid');
  if (typeof value.bearer_token !== 'string' || !value.bearer_token.trim() || /[\r\n]/.test(value.bearer_token)) {
    return invalid('provision_token_invalid');
  }
  return {
    ok: true,
    provision: {
      schema_version: 1,
      source: SOURCE,
      base_url: new URL(value.base_url).origin + '/',
      bearer_token: value.bearer_token,
      allowed_domains: [...ALLOWED_DOMAINS],
    },
  };
}

export function validateCapabilities(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return invalid('capabilities_invalid');
  if (value.version !== 1 || value.source !== SOURCE || !exactDomains(value.domains)) {
    return invalid('capabilities_contract_invalid');
  }
  if (value.storage_receipt_version !== 1 || value.max_event_bytes !== MAX_EVENT_BYTES ||
      value.max_chunk_bytes !== MAX_CHUNK_BYTES || value.finalize_replay_safe !== true) {
    return invalid('capabilities_contract_invalid');
  }
  return { ok: true, capabilities: value };
}

async function readBounded(response, limit) {
  if (response.body?.getReader) {
    const reader = response.body.getReader();
    const chunks = [];
    let total = 0;
    try {
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        total += part.value.byteLength;
        if (total > limit) {
          await reader.cancel();
          return null;
        }
        chunks.push(part.value);
      }
    } finally {
      reader.releaseLock();
    }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return new TextDecoder().decode(bytes);
  }
  const text = await response.text();
  return new TextEncoder().encode(text).byteLength <= limit ? text : null;
}

export async function probeCapabilities(provision, fetchImpl = globalThis.fetch, options = {}) {
  const checked = validateProvision(provision);
  if (!checked.ok) return checked;
  if (typeof fetchImpl !== 'function') return invalid('connection_failed');
  const timeoutMs = Number.isFinite(options.timeoutMs) && options.timeoutMs > 0 ? options.timeoutMs : 10_000;
  const controller = typeof AbortController === 'function' ? new AbortController() : null;
  let timer;
  try {
    timer = setTimeout(() => controller?.abort(), timeoutMs);
    const response = await fetchImpl(new URL('/v1/capabilities', checked.provision.base_url).toString(), {
      method: 'GET',
      headers: { Authorization: `Bearer ${checked.provision.bearer_token}` },
      redirect: 'error',
      ...(controller ? { signal: controller.signal } : {}),
    });
    if (!response || response.status < 200 || response.status >= 300) {
      return invalid(response?.status >= 300 && response?.status < 400 ? 'redirect_not_allowed' : 'http_status');
    }
    const raw = await readBounded(response, MAX_PROVISION_BYTES);
    if (raw === null) return invalid('response_too_large');
    let value;
    try { value = JSON.parse(raw); } catch { return invalid('capabilities_invalid'); }
    return validateCapabilities(value);
  } catch (error) {
    return invalid(error?.name === 'AbortError' ? 'timeout' : 'connection_failed');
  } finally {
    clearTimeout(timer);
  }
}

export async function parseProvisionFile(file) {
  if (!file || typeof file.size !== 'number' || file.size > MAX_PROVISION_BYTES) return invalid('provision_too_large');
  let value;
  try { value = JSON.parse(await file.text()); } catch { return invalid('provision_invalid'); }
  return validateProvision(value);
}

export const PROVISION_LIMIT_BYTES = MAX_PROVISION_BYTES;

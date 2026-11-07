/**
 * In-memory location store with UUID deduplication.
 *
 * - Dedup: UUID Set with 1-hour TTL (prevents Background URLSession retries
 *   from creating duplicate entries)
 * - History: circular buffer of last 100 samples
 * - Latest: most recent location for quick access
 */

const DEDUP_TTL_MS = 60 * 60 * 1000; // 1 hour
const DEDUP_MAX = 10_000;
const HISTORY_MAX = 100;

/** @type {Map<string, number>} uuid -> timestamp */
const seenIds = new Map();

/** @type {object[]} */
const history = [];

/** @type {object | null} */
let latestLocation = null;

// Entries are insertion ordered. Expire them on access instead of creating an
// import-time timer that survives plugin reload and keeps Gateway shutdown alive.
function pruneExpired(now = Date.now()) {
  const cutoff = now - DEDUP_TTL_MS;
  for (const [id, ts] of seenIds) {
    if (ts > cutoff) break;
    seenIds.delete(id);
  }
}

/**
 * Check if a sample ID has already been seen.
 * @param {string} id
 * @returns {boolean}
 */
export function isDuplicate(id) {
  if (!id) return false;
  pruneExpired();
  return seenIds.has(id);
}

/**
 * Store a location sample (after dedup check).
 * @param {object} sample - { id, lat, lon, accuracy, timestamp, altitude?, speed?, bearing?, ... }
 * @returns {boolean} true if stored, false if duplicate
 */
export function storeSample(sample) {
  if (!sample || typeof sample.id !== "string" || !sample.id) return false;
  const now = Date.now();
  pruneExpired(now);
  if (seenIds.has(sample.id)) return false;

  while (seenIds.size >= DEDUP_MAX) {
    seenIds.delete(seenIds.keys().next().value);
  }
  seenIds.set(sample.id, now);

  const entry = {
    ...sample,
    receivedAt: new Date().toISOString(),
  };

  history.push(entry);
  if (history.length > HISTORY_MAX) {
    history.shift();
  }

  latestLocation = entry;
  globalThis.__vibetermLatestLocation = entry;
  return true;
}

/**
 * Get the most recent location.
 * @returns {object | null}
 */
export function getLatest() {
  return latestLocation;
}

/**
 * Get recent location history.
 * @param {number} [limit=10]
 * @returns {object[]}
 */
export function getHistory(limit = 10) {
  return history.slice(-limit);
}

/**
 * Get store stats for debugging.
 * @returns {{ dedupSize: number, historySize: number, hasLatest: boolean }}
 */
export function getStats() {
  pruneExpired();
  return {
    dedupSize: seenIds.size,
    historySize: history.length,
    hasLatest: latestLocation !== null,
  };
}

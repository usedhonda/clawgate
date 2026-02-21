/**
 * POST /api/telemetry handler.
 *
 * Accepts batched location samples + health summary from Vibeterm iOS (Background URLSession).
 * Deduplicates by UUID and stores in memory.
 *
 * Request:
 *   POST /api/telemetry
 *   Authorization: Bearer <gateway-token>
 *   Content-Type: application/json
 *   {
 *     "samples": [{ "id": "uuid", "lat": 35.6, "lon": 139.6, "accuracy": 10.0, "timestamp": "ISO8601", ... }],
 *     "health": {
 *       "periodStart": "ISO8601", "periodEnd": "ISO8601",
 *       "steps": 5000, "activeEnergyKcal": 200.0, "distanceMeters": 3500.0,
 *       "heartRateAvg": 72.0, "heartRateMin": 55.0, "heartRateMax": 120.0,
 *       "restingHeartRate": 58.0, "hrvAvgMs": 45.0,
 *       "bloodOxygenPercent": 98.0, "respiratoryRateAvg": 16.0,
 *       "bodyMassKg": null, "bodyTemperatureCelsius": null, "wristTemperatureCelsius": null,
 *       "sleepMinutes": { "total": 420, "deep": 90, "rem": 100, "core": 200, "awake": 30 },
 *       "workouts": [{ "activityType": "Running", "durationSeconds": 1800, "energyKcal": 300 }]
 *     }
 *   }
 *
 * Response:
 *   200: { "received": N, "nextMinIntervalSec": 60 }
 *   401: { "error": { "code": "UNAUTHORIZED", "message": "..." } }
 *   400: { "error": { "code": "BAD_REQUEST", "message": "..." } }
 *   405: { "error": { "code": "METHOD_NOT_ALLOWED", "message": "..." } }
 */

import { promises as fs } from "fs";
import { join } from "path";
import { homedir } from "os";
import { verifyAuth } from "./auth.js";
import { storeSample, isDuplicate } from "./store.js";

const NEXT_MIN_INTERVAL_SEC = 60;

// Location diary throttle state
let lastDiaryWrite = { lat: 0, lon: 0, time: 0 };

const DIARY_MOVE_THRESHOLD_M = 200;
const DIARY_TIME_THRESHOLD_MS = 30 * 60 * 1000;

// Health diary throttle: skip if same periodEnd written within 10 minutes
let lastHealthWrite = { periodEndMs: 0 };
const HEALTH_DIARY_INTERVAL_MS = 10 * 60 * 1000;

/**
 * Haversine distance in meters between two lat/lon points.
 */
function haversineM(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Append a location entry to today's diary file if throttle conditions are met.
 * @param {object} sample - { lat, lon, accuracy, timestamp }
 * @param {object} [log] - logger
 */
async function maybeWriteDiary(sample, log) {
  const now = Date.now();
  const dist = lastDiaryWrite.time
    ? haversineM(lastDiaryWrite.lat, lastDiaryWrite.lon, sample.lat, sample.lon)
    : Infinity;
  const elapsed = now - lastDiaryWrite.time;

  if (dist < DIARY_MOVE_THRESHOLD_M && elapsed < DIARY_TIME_THRESHOLD_MS) {
    return; // throttled
  }

  const ts = sample.timestamp ? new Date(sample.timestamp) : new Date();
  const iso = ts.toISOString();
  const timeStr = iso.slice(11, 16) + "Z"; // HH:MMZ (UTC)
  const dateStr = iso.slice(0, 10); // YYYY-MM-DD (UTC)

  const acc = typeof sample.accuracy === "number" ? Math.round(sample.accuracy) : "?";
  const line = `\u{1F4CD} ${timeStr} - ${sample.lat.toFixed(4)}, ${sample.lon.toFixed(4)} (accuracy ${acc}m)\n`;

  const memoryDir = join(homedir(), ".openclaw", "workspace", "memory");
  const diaryPath = join(memoryDir, `${dateStr}.md`);

  try {
    await fs.mkdir(memoryDir, { recursive: true });
    await fs.appendFile(diaryPath, line, "utf-8");
    lastDiaryWrite = { lat: sample.lat, lon: sample.lon, time: now };
    log?.debug?.(`vibeterm-telemetry: diary entry written to ${dateStr}.md`);
  } catch (err) {
    log?.warn?.(`vibeterm-telemetry: failed to write diary: ${err.message}`);
  }
}

/**
 * Append a health entry (❤️) to the diary file if health data is present.
 * Uses periodEnd as the diary timestamp. Throttled to avoid duplicate writes.
 * @param {object} health - HealthSummary from Vibeterm
 * @param {object} [log] - logger
 */
async function maybeWriteHealthDiary(health, log) {
  if (!health || typeof health !== "object") return;

  // Need at least one meaningful field
  const hasData =
    health.steps != null ||
    health.heartRateAvg != null ||
    health.bloodOxygenPercent != null ||
    health.activeEnergyKcal != null;
  if (!hasData) return;

  // Throttle by periodEnd
  const periodEndMs = health.periodEnd ? new Date(health.periodEnd).getTime() : Date.now();
  if (Math.abs(periodEndMs - lastHealthWrite.periodEndMs) < HEALTH_DIARY_INTERVAL_MS) {
    return;
  }

  const ts = health.periodEnd ? new Date(health.periodEnd) : new Date();
  const iso = ts.toISOString();
  const timeStr = iso.slice(11, 16) + "Z"; // HH:MMZ (UTC)
  const dateStr = iso.slice(0, 10); // YYYY-MM-DD (UTC)

  // Build ❤️ line parts
  const parts = [];

  if (health.steps != null) parts.push(`${health.steps} steps`);
  if (health.activeEnergyKcal != null) parts.push(`${Math.round(health.activeEnergyKcal)}kcal`);
  if (health.distanceMeters != null) parts.push(`${(health.distanceMeters / 1000).toFixed(1)}km`);

  if (health.heartRateAvg != null) {
    const avg = Math.round(health.heartRateAvg);
    if (health.heartRateMin != null && health.heartRateMax != null) {
      parts.push(`HR ${avg} (${Math.round(health.heartRateMin)}-${Math.round(health.heartRateMax)})bpm`);
    } else {
      parts.push(`HR ${avg}bpm`);
    }
  }
  if (health.restingHeartRate != null) parts.push(`RHR ${Math.round(health.restingHeartRate)}bpm`);
  if (health.hrvAvgMs != null) parts.push(`HRV ${Math.round(health.hrvAvgMs)}ms`);
  if (health.bloodOxygenPercent != null) parts.push(`SpO2 ${Math.round(health.bloodOxygenPercent)}%`);
  if (health.respiratoryRateAvg != null) parts.push(`resp ${Math.round(health.respiratoryRateAvg)}/min`);
  if (health.bodyTemperatureCelsius != null) parts.push(`temp ${health.bodyTemperatureCelsius.toFixed(1)}C`);
  if (health.wristTemperatureCelsius != null) parts.push(`wrist ${health.wristTemperatureCelsius.toFixed(1)}C`);
  if (health.bodyMassKg != null) parts.push(`${health.bodyMassKg.toFixed(1)}kg`);

  if (health.sleepMinutes != null) {
    const s = health.sleepMinutes;
    const totalMin = s.total ?? ((s.deep ?? 0) + (s.rem ?? 0) + (s.core ?? 0) + (s.awake ?? 0));
    const hours = (totalMin / 60).toFixed(1);
    const stageParts = [];
    if (s.deep != null) stageParts.push(`deep ${Math.round(s.deep)}m`);
    if (s.rem != null) stageParts.push(`REM ${Math.round(s.rem)}m`);
    if (s.core != null) stageParts.push(`core ${Math.round(s.core)}m`);
    if (s.awake != null) stageParts.push(`awake ${Math.round(s.awake)}m`);
    parts.push(`sleep ${hours}h${stageParts.length ? ` (${stageParts.join(", ")})` : ""}`);
  }

  if (Array.isArray(health.workouts) && health.workouts.length > 0) {
    const wParts = health.workouts.map((w) => {
      let s = w.activityType ?? "workout";
      if (w.durationSeconds != null) s += ` ${Math.round(w.durationSeconds / 60)}min`;
      if (w.energyKcal != null) s += ` ${Math.round(w.energyKcal)}kcal`;
      return s;
    });
    parts.push(`workouts: ${wParts.join(", ")}`);
  }

  if (parts.length === 0) return;

  const line = `\u2764\uFE0F ${timeStr} - ${parts.join(" | ")}\n`;

  const memoryDir = join(homedir(), ".openclaw", "workspace", "memory");
  const diaryPath = join(memoryDir, `${dateStr}.md`);

  try {
    await fs.mkdir(memoryDir, { recursive: true });
    await fs.appendFile(diaryPath, line, "utf-8");
    lastHealthWrite = { periodEndMs };
    log?.info?.(`vibeterm-telemetry: health diary written to ${dateStr}.md`);
  } catch (err) {
    log?.warn?.(`vibeterm-telemetry: failed to write health diary: ${err.message}`);
  }
}

/**
 * Read the full request body as a string.
 * @param {import("http").IncomingMessage} req
 * @returns {Promise<string>}
 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    req.on("error", reject);
  });
}

/**
 * Send a JSON error response.
 * @param {import("http").ServerResponse} res
 * @param {number} status
 * @param {string} code
 * @param {string} message
 */
function sendError(res, status, code, message) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: { code, message } }));
}

/**
 * Send a JSON success response.
 * @param {import("http").ServerResponse} res
 * @param {object} data
 */
function sendJson(res, data) {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

/**
 * Create the telemetry handler bound to a plugin API instance.
 * @param {object} api - OpenClaw plugin API
 * @returns {(req: import("http").IncomingMessage, res: import("http").ServerResponse) => Promise<void>}
 */
export function createTelemetryHandler(api) {
  const gatewayToken = api.config?.gateway?.auth?.token;
  const log = api.logger;

  if (!gatewayToken) {
    log?.warn?.("vibeterm-telemetry: no gateway auth token found in config");
  }

  return async (req, res) => {
    // Method check
    if (req.method !== "POST") {
      sendError(res, 405, "METHOD_NOT_ALLOWED", "Only POST is accepted");
      return;
    }

    // Auth check
    if (gatewayToken) {
      const auth = verifyAuth(req, gatewayToken);
      if (!auth.valid) {
        log?.debug?.(`vibeterm-telemetry: auth failed: ${auth.error}`);
        sendError(res, 401, "UNAUTHORIZED", auth.error);
        return;
      }
    }

    // Parse body
    let body;
    try {
      const raw = await readBody(req);
      body = JSON.parse(raw);
    } catch (err) {
      sendError(res, 400, "BAD_REQUEST", "Invalid JSON body");
      return;
    }

    // Validate samples array
    const samples = body.samples;
    if (!Array.isArray(samples)) {
      sendError(res, 400, "BAD_REQUEST", "\"samples\" must be an array");
      return;
    }

    // Process samples with dedup
    let received = 0;
    for (const sample of samples) {
      if (!sample.id || typeof sample.lat !== "number" || typeof sample.lon !== "number") {
        log?.debug?.(`vibeterm-telemetry: skipping invalid sample: ${JSON.stringify(sample).slice(0, 100)}`);
        continue;
      }
      if (storeSample(sample)) {
        received++;
        maybeWriteDiary(sample, log).catch(() => {}); // fire-and-forget
      }
    }

    // Process health data
    const health = body.health;
    let healthReceived = false;
    if (health && typeof health === "object") {
      healthReceived = true;
      await maybeWriteHealthDiary(health, log);
    }

    log?.info?.(`vibeterm-telemetry: processed ${samples.length} samples, ${received} new, health=${healthReceived}`);

    sendJson(res, {
      received,
      nextMinIntervalSec: NEXT_MIN_INTERVAL_SEC,
    });
  };
}

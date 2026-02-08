/**
 * POST /api/telemetry handler.
 *
 * Accepts batched location samples from Vibeterm iOS (Background URLSession).
 * Deduplicates by UUID and stores in memory.
 *
 * Request:
 *   POST /api/telemetry
 *   Authorization: Bearer <gateway-token>
 *   Content-Type: application/json
 *   { "samples": [{ "id": "uuid", "lat": 35.6, "lon": 139.6, "accuracy": 10.0, "timestamp": "ISO8601", ... }] }
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

// Diary throttle state
let lastDiaryWrite = { lat: 0, lon: 0, time: 0 };

const DIARY_MOVE_THRESHOLD_M = 200;
const DIARY_TIME_THRESHOLD_MS = 30 * 60 * 1000;

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
  const timeStr = ts.toLocaleTimeString("ja-JP", {
    timeZone: "Asia/Tokyo",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const dateStr = ts.toLocaleDateString("en-CA", { timeZone: "Asia/Tokyo" }); // YYYY-MM-DD

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

    log?.info?.(`vibeterm-telemetry: processed ${samples.length} samples, ${received} new`);

    sendJson(res, {
      received,
      nextMinIntervalSec: NEXT_MIN_INTERVAL_SEC,
    });
  };
}

import assert from "node:assert/strict";
import test from "node:test";
import { getHistory, getStats, isDuplicate, storeSample } from "../store.js";

test("dedup expires on access and remains bounded during a large burst", (t) => {
  let now = 1_800_000_000_000;
  t.mock.method(Date, "now", () => now);
  assert.equal(storeSample({ id: "expiry", lat: 0, lon: 0 }), true);
  assert.equal(isDuplicate("expiry"), true);
  assert.equal(storeSample({ id: "expiry", lat: 0, lon: 0 }), false);
  now += 60 * 60 * 1000;
  assert.equal(isDuplicate("expiry"), false);
  assert.equal(storeSample({ id: "expiry", lat: 0, lon: 0 }), true);

  for (let i = 0; i < 10_100; i++) {
    storeSample({ id: `burst-${i}`, lat: 0, lon: 0 });
  }
  assert.equal(getStats().dedupSize, 10_000);
  assert.equal(getHistory(1000).length, 100);
  assert.equal(isDuplicate("burst-10099"), true);
  assert.equal(isDuplicate("burst-0"), false);
});

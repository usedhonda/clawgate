import test from "node:test";
import assert from "node:assert/strict";
import { prepareInboundEventProjection } from "../gateway.js";

test("projects frozen poll events while preserving ordered originals for coalescing", () => {
  const first = Object.freeze({ id: 11, adapter: "line", payload: Object.freeze({ text: "raw one" }) });
  const second = Object.freeze({ id: 12, adapter: "line", payload: Object.freeze({ text: "raw two" }) });

  const firstProjection = prepareInboundEventProjection(first, "normalized one");
  const secondProjection = prepareInboundEventProjection(second, "normalized two");
  firstProjection.event.payload.text = "merged text";

  assert.notStrictEqual(firstProjection.event, first);
  assert.equal(firstProjection.event.payload.text, "merged text");
  assert.equal(first.payload.text, "raw one");
  assert.deepEqual(
    [...firstProjection.originalEvents, ...secondProjection.originalEvents],
    [first, second],
  );
  assert.strictEqual(firstProjection.originalEvents[0], first);
  assert.strictEqual(secondProjection.originalEvents[0], second);
});

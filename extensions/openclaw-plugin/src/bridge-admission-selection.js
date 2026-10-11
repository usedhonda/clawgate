import { verifiedBridgePollEvidence } from "./bridge-admission.js";

/**
 * Prepare ordered original verified events for a future bridge receiver.
 * No event projection, origin inference, or receiver invocation occurs here.
 */
export function prepareBridgeAdmissionPolls(originalEvents) {
  if (!Array.isArray(originalEvents) || originalEvents.length === 0) return null;

  const polls = [];
  const closedEnvelopes = new Set();
  let current = null;

  for (const originalEvent of originalEvents) {
    const evidence = verifiedBridgePollEvidence(originalEvent);
    if (!evidence || !evidence.envelope || !Number.isSafeInteger(evidence.eventIndex)
        || evidence.eventIndex < 0) return null;

    const { envelope, eventIndex } = evidence;
    if (!current || current.envelope !== envelope) {
      if (current) closedEnvelopes.add(current.envelope);
      if (closedEnvelopes.has(envelope)) return null;
      current = { envelope, eventIndexes: [eventIndex] };
      polls.push(current);
      continue;
    }

    const previousIndex = current.eventIndexes[current.eventIndexes.length - 1];
    if (eventIndex <= previousIndex) return null;
    current.eventIndexes.push(eventIndex);
  }

  return Object.freeze(polls.map(({ envelope, eventIndexes }) => Object.freeze({
    envelope,
    eventIndexes: Object.freeze(eventIndexes),
  })));
}

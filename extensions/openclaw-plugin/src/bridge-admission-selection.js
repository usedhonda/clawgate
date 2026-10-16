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

export function createHostBridgePollSession({ runtime, accountId, issuerPublicKeyHex, poll }) {
  if (!runtime?.issuePollRequest || !runtime.preparePoll || !runtime.receivePrepared || !runtime.bindContext) {
    throw new Error("bridge_poll_host_runtime_unavailable");
  }
  const capabilities = new WeakMap();
  return Object.freeze({
    async poll(apiUrl, since) {
      const issued = await runtime.issuePollRequest({ accountId, since });
      if (issued?.status !== "issued" || issued.request?.accountId !== accountId) {
        throw new Error("bridge_poll_host_request_unavailable");
      }
      const response = await poll(apiUrl, since, { issuerPublicKeyHex, pollRequest: issued.request });
      if (response.events?.length) {
        const evidence = verifiedBridgePollEvidence(response.events[0]);
        if (!evidence) throw new Error("bridge_poll_original_evidence_missing");
        const prepared = await runtime.preparePoll({ accountId, envelope: evidence.envelope });
        if (prepared?.status !== "prepared") throw new Error("bridge_poll_host_prepare_failed");
        capabilities.set(evidence.envelope, prepared.capability);
      }
      return response;
    },
    async bind(context, originalEvents) {
      const selected = prepareBridgeAdmissionPolls(originalEvents);
      if (!selected) throw new Error("bridge_poll_original_group_missing");
      const polls = selected.map(({ envelope, eventIndexes }) => {
        const capability = capabilities.get(envelope);
        if (!capability) throw new Error("bridge_poll_prepared_capability_missing");
        return { capability, eventIndexes };
      });
      const received = await runtime.receivePrepared({ accountId, polls });
      if (received?.status !== "accepted" || !await runtime.bindContext(context, received.capability)) {
        throw new Error("bridge_poll_group_not_bound");
      }
    },
  });
}

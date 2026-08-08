# Pet Log Window — Contract Spec

Normative contract for the Pet Log query pipeline (client → model → client),
its parser acceptance rules, and its transport/telemetry privacy. Public-safe:
this document must never contain real hostnames, IP addresses, network ids,
personal names/accounts, or secrets.

## Operating rule

Any change to the behavior this spec covers MUST update the corresponding
section in the SAME commit. Sections are split into:

- **Normative (shipped)** — the current, implemented contract. Guards enforce it.
- **Target (not yet shipped)** — planned for a later commit/Wave. Not yet
  enforced. A commit that ships one of these promotes it into the Normative
  section in the same commit.

The `policyVersion` string quoted in this spec must equal
`PetLogPromptBuilder.policyVersion` in code (a guard test asserts this).

## Boundary with the OpenClaw ecosystem

The client owns the query envelope, the universal prefix (policy text), the
response parser, and client-side telemetry. The Gateway/model wire contract
(session routing, run correlation, event delivery) is normative in the
`oc-general` repository under `docs/contracts/`. Changes here stay inside the
client: the prefix and `policyVersion` are client-internal and add no new
fields to the Gateway wire contract.

---

## Normative (shipped)

### Policy version

`policyVersion` = `pet-log-context-v1`. It is emitted as a literal tag at the
top of the universal prefix and echoed in the response schema; the parser
rejects a reply whose `contextDecision.policyVersion` does not match.

### Transport privacy (D59)

The WebSocket transport logs only BOUNDED, body-free structural metadata about a
response. The server-controlled `error.message` is never logged. Response id,
payload type, and error code are wire-controlled and reduced before logging:

- response id: a short prefix + length for our OWN in-flight ids; a
  non-reversible hash tag + length for unknown (wire) ids.
- payload type: an allowlisted protocol token verbatim, else a hash tag + length.
- error code: an allowlisted fixed code verbatim, else a hash tag + length.
- error message: length only.

The primary guard drives the real response-handling callsite through an
injectable sink and asserts the emitted line carries no wire content; a
multiline source scan is an auxiliary.

### Telemetry (D139)

The whole Pet Log admission lifecycle (actionReceived, busyRefused,
disconnectedRefused, envelopeAccepted, dispatchAttempted, persistenceFailure,
envelopeSent, summonReplyTimeout) is emitted through one os.Logger
(subsystem `com.clawgate`, category `PetLog`) so `log show` can query it
retroactively — NSLog is not retroactively queryable. Every event is body-free
(no instruction, STT, or error body) and carries a `requestId` (or, where none
exists, a bounded owner/correlation token) so the lifecycle correlates end to
end.

---

## Target (not yet shipped — upcoming A2 commits)

The following are planned for the remaining Wave A2 commits and are NOT yet the
enforced contract. Each will be promoted into the Normative section in the
commit that ships it.

- **policyVersion → `pet-log-context-v2`** and the prefix v2 contract:
  scopeOverride means the client has already applied the hard scope
  (segments are the exact target, no model re-resolution; a scene id is an
  epoch integer, not a segment id); session-contamination clause (evidence is
  only the envelope segments); insufficient-evidence clause.
- **selection semantics**: explicit scope = exact-all inclusion; automatic scope
  = anchor-anchored contiguous backward suffix only.
- **parser acceptance**: required `selectionMode`, duplicate-id rejection,
  response bounds (answer/reason-code/correction-count limits), parser-failure
  metadata retention.

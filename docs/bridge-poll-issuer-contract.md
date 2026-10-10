# Authenticated bridge poll response

The optional `X-ClawGate-Challenge` request header enables the bridge-owned
issuer. It is accepted only as exactly 64 lowercase hexadecimal characters.
The response preserves the existing top-level poll fields and event fields,
adds the independent admission metadata, and signs the exact returned bytes with:

- `X-ClawGate-Issuer-Version: 1`
- `X-ClawGate-Issuer-Key-Id: SHA256(raw Ed25519 public key)` (lowercase hex)
- `X-ClawGate-Issuer-Signature: base64 Ed25519`

The signature covers `clawgate.poll.v1`, then each of method (`GET`), exact
request URI, challenge, decimal status, key id, and lowercase SHA256 of the
exact response body. Each value is encoded as a uint32 big-endian byte length
followed by UTF-8 bytes. Invalid challenges return a structured failure and are
never signed; an absent challenge remains the legacy unsigned poll.

Events carry a body-free immutable `admission` envelope. Watcher and debug
emitters use closed provenance methods; generic appends are `unknown`. The
private issuer store is optional and disabled unless an owner-readable key,
persistent generation/admissions pair, and explicitly provisioned record and
byte limits are coherent. Production never recreates a missing pair under an
existing key. Generic events carry only the closed unknown sentinel; they do
not consume admission capacity. The append-only journal contains no event body.
Storage/key failures remain `unknown` and do not suppress normal events.


## Explicit provisioning and verification

`scripts/provision-bridge-issuer.mjs --max-records N --max-bytes N` establishes
one protected key, public pin, generation and empty journal after the limits
have been adopted. It refuses existing material and never rotates or resets it.
Key values are not printed. Only the public pin may be distributed to the
plugin; the private key stays on the bridge host.

The plugin's protected poll mode is explicit: a pinned public key, a fresh
challenge per request, redirect refusal, and signature verification before JSON
admission is used. Copied payloads cannot mint the local verified-event binding.
The signed debug provenance remains debug. Missing proof is unknown, not a
LINE-origin assertion, author authentication or command permission.

`Tests/Fixtures/bridge-poll-signing-v1.json` is an intentionally synthetic
Swift/Node exact-byte vector, not a deployment key. Source tests and an unsigned
compatibility poll do not prove caller activation or phone playback.

## Prepared reply expectation wire

The plugin can prepare a closed version-1 `expect` object from its own semantic
handle. Missing or non-enum origin becomes explicit `unknown`; source and policy
sessions remain independent nullable strings, each bounded to 512 UTF-16 units.
Destination or policy is never used to infer LINE origin. Copied handles fail.
This serializer sends no RPC and does not establish host admission authority.
The new observation/confirmation caller remains inactive pending host-owned
verified admission carry and the complete exclusive-owner acceptance.

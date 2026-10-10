# Authenticated bridge poll response

The optional `X-ClawGate-Challenge` request header enables the bridge-owned
issuer. It is accepted only as exactly 64 lowercase hexadecimal characters.
The response keeps the legacy JSON bytes unchanged and adds:

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
persistent generation, and explicitly provisioned record limit are coherent.
Storage/key failures remain `unknown` and do not suppress normal events.

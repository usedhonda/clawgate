# OpenClaw compatibility review

Reviewed on 2026-11-07 against the official **v2026.11.1** source at commit
`4ffdd2047d192dd65554de3c8c46c0e0197c6e2a`.
This is a source compatibility review plus local plugin regression tests. It is
not an end-to-end certification of a running macOS application and Gateway.

Keep the exact Gateway version recorded in deployment configuration and review
these boundaries when upgrading. A locally patched Gateway has a second
compatibility surface: its patch revision must also match the workflows enabled
in ClawGate.

## Official host interfaces

| Surface | v2026.11.1 contract | ClawGate assessment |
| --- | --- | --- |
| Node.js | `>=24.16.0 <25 || >=26.1.0` in the host package | Plugin package metadata now matches this range. Tests were run on Node.js 24.22.1. |
| WebSocket wire version | Current protocol and minimum ordinary-client protocol are 4 | The native client's `minProtocol: 3, maxProtocol: 4` overlaps version 4. There is no need to discard that existing negotiation range. |
| Device proof | Current verifier accepts both v3 and nonce-bearing v2 signatures | The ordinary native client's v2 proof remains accepted. The challenge nonce, device identity, timestamp and signed client tuple must still validate. |
| Ordinary client identity | `cli` is a valid client ID and mode | The normal `cli` / `cli` connection matches the published schema. |
| Session storage | `runtime.agent.session.resolveStorePath(config.session?.store, { agentId })` resolves the host storage path | Inbound recording now uses this API and the same owner selected for the session key. The previous `runtime.config.storePath` lookup referenced a property absent from the public runtime and silently skipped recording. |
| Inbound session recording | `runtime.channel.session.recordInboundSession` still exists, but is deprecated in favor of channel turn helpers | Existing dispatch is preserved for this bounded repair. The host owns the store write and route update. A future migration should adopt the host's channel turn helpers together with its admission and dispatch behavior. |
| Plugin HTTP routes | `registerHttpRoute` requires `auth: "gateway"` or `auth: "plugin"` | The telemetry extension registers an exact route with `auth: "gateway"`; Gateway resolves and applies its own authentication. Omitting `auth` causes current registration to be rejected. |

Upstream evidence:

- [Host package and Node engine range](https://github.com/openclaw/openclaw/blob/v2026.11.1/package.json)
- [Protocol version constants](https://github.com/openclaw/openclaw/blob/v2026.11.1/packages/gateway-protocol/src/version.ts)
- [Client IDs and modes](https://github.com/openclaw/openclaw/blob/v2026.11.1/packages/gateway-protocol/src/client-info.ts)
- [Connect frame schema](https://github.com/openclaw/openclaw/blob/v2026.11.1/packages/gateway-protocol/src/schema/frames.ts)
- [v3/v2 device signature verification](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/gateway/server/ws-connection/handshake-auth-helpers.ts)
- [Core plugin runtime, including config and agent session APIs](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/plugins/runtime/types-core.ts)
- [Channel runtime APIs and deprecations](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/plugins/runtime/types-channel.ts)
- [Host inbound recording implementation](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/channels/session.ts)
- [HTTP route registration validation](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/plugins/registry-registrars-network.ts)

## Workflows requiring a host extension

The following are not official v2026.11.1 capabilities. Updating a stock Gateway
alone does not enable them:

- **Retained-minutes connection.** ClawGate's dedicated connection uses
  `gateway-client` / `interactive`, `connect.executionPurpose`, and a matching
  `hello` execution-connection acknowledgement. The official mode enumeration
  does not include `interactive`, and its closed connect schema does not include
  `executionPurpose`. The dedicated connection requires the corresponding host
  extension; the ordinary `cli` connection has a different compatibility status.
- **Protected bridge admission.** The plugin's signed ingress path expects
  `runtime.channel.inbound.bridgeAdmission` helpers from its host integration.
  These are not present in the reviewed official plugin runtime. Preserve the
  admission boundary when updating that integration. Screen text or an arbitrary
  session-key string must not substitute for host-issued authority.

Do not remove these checks or downgrade to an unprotected path to make an
unsupported Gateway appear compatible. Verify the enabled workflow against the
actual Gateway build before deployment.

## Remaining integration limits

**Agent selection:** the plugin's existing session builder selects the first
configured agent entry, with `main` as a fallback. The recording repair reuses
that selection; it does not implement all current host binding or system-agent
selection rules. Multi-agent deployments need a separate routing migration and
regression coverage before they can claim those rules are honored.

**Native Gateway credential discovery:** the macOS application's existing
file-based configuration reader supports a literal token in JSON. Official
OpenClaw also accepts JSON5 configuration and resolves credentials from environment
variables and secret references. Such a Gateway configuration can be valid while
that native discovery path cannot obtain the credential. Check the native
client's supported configuration before adopting these forms; never work around
this by disabling Gateway authentication. See the upstream
[configuration parser](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/config/io.ts)
and [token resolution](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/gateway/auth-token-resolution.ts).

**Bridge access:** OpenClaw Gateway authentication and the native ClawGate HTTP
bridge have separate security boundaries. An optional plugin account Bearer
header does not authenticate the native bridge. Use the network restrictions
described in the [main README](../README.md); for remote access, configure host
firewall and tailnet access controls for the actual listener.

## Regression coverage for this review

The added tests exercise the affected paths:

- A tmux target containing shell substitutions and shell metacharacters is passed
  as one literal subprocess argument. No injected command is executed; tmux
  failure still returns no working directory.
- Inbound dispatch records session metadata before reply dispatch using a runtime
  with the official public shape, which has no `runtime.config.storePath`. The
  compatibility resolver under `channel.session` is also covered. Screen-derived
  input remains command-unauthorized.
- Default and fallback account IDs survive configuration resolution, and null,
  array and scalar metadata values are not exposed as accounts.

Run from the repository root:

```bash
node --experimental-test-module-mocks --test extensions/openclaw-plugin/src/__tests__/*.test.js
```

The full plugin suite passed locally. macOS builds, live Gateway handshakes,
protected ingress and actual messaging still require verification in an
appropriately configured integration environment.

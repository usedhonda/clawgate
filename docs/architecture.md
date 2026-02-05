# AppBridge Architecture

- UI: menu bar app (`NSStatusItem`) + settings (`SwiftUI`)
- Core:
  - `BridgeServer`: localhost HTTP/SSE server (SwiftNIO)
  - `BridgeCore`: routing, validation, auth, adapter dispatch
  - `EventBus`: poll and SSE event delivery
  - `ConfigStore` + `BridgeTokenManager`
- Automation:
  - `AXQuery`, `AXActions`, `AXDump`
  - `RetryPolicy`
- Adapter:
  - `LINEAdapter` (`send_message` flow + StepLog)

## API surface

- `GET /v1/health`
- `POST /v1/send` (requires `X-Bridge-Token`)
- `GET /v1/poll?since=` (requires `X-Bridge-Token`)
- `GET /v1/events` SSE (requires `X-Bridge-Token`)
- `GET /v1/axdump` (debug endpoint, requires `X-Bridge-Token`)

## Intel Mac support

- Minimum target is `macOS 12` to support older Intel Mac mini environments.
- Build architecture is handled by the local toolchain (`arm64` on Apple Silicon, `x86_64` on Intel).
- For cross-build from Apple Silicon, use:
  - `swift build -Xswiftc -target -Xswiftc x86_64-apple-macos12.0`

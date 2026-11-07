# Contributing to ClawGate

Thanks for contributing. This project combines a macOS Swift app, shell tooling, and JavaScript-based OpenClaw plugins.

## Development requirements

- macOS 12 or newer
- Xcode 26.3 or newer (the Speech framework source requires its SDK; CI uses 26.3)
- Node.js 24.22.1 (the version used by CI for plugin and extension tests)
- Accessibility permission for local AX-dependent testing
- Screen Recording permission if you test OCR-based LINE flows

## Build

```bash
swift build
```

For the full local app cycle, including signing and launch:

```bash
./scripts/restart-local-clawgate.sh
```

## Tests

Run the Swift test suite:

```bash
swift test
```

Run plugin tests:

```bash
node --experimental-test-module-mocks --test extensions/openclaw-plugin/src/__tests__/*.test.js
```

Run Chrome extension tests:

```bash
node --test extensions/clawgate-chrome/*.test.js extensions/clawgate-chrome/tests/*.test.js
```

For OpenClaw host compatibility and the distinction between upstream and custom
Gateway capabilities, see [OpenClaw compatibility](docs/openclaw-compatibility.md).
The installed host and the declared plugin compatibility range must be validated
together before deploying a host upgrade.

Optional checks:

```bash
node --check extensions/openclaw-plugin/src/gateway.js
node --check extensions/vibeterm-telemetry/index.js
bash scripts/security-leak-check.sh --all
```

## Code style

### Swift

- Keep changes small and local to the task.
- Prefer the existing project patterns over broad refactors.
- Preserve app behavior unless the task explicitly changes it.

### JavaScript

- ESM modules
- 2-space indentation
- Semicolons
- Prefer small pure helpers when adding parsing / normalization logic

### Shell

- POSIX-ish Bash where practical
- ASCII-only operators and symbols
- Keep scripts explicit and readable

## Pull requests

Please include:

- a short problem statement
- what changed and why
- build/test commands you ran
- screenshots for visible UI changes
- notes about permissions or environment-specific behavior when relevant

Small, focused pull requests are easier to review than broad mixed changes.

## OpenClaw plugin notes

The repository includes OpenClaw plugins under `extensions/`.

- `extensions/openclaw-plugin/` powers AI review and tmux message dispatch through ClawGate
- `extensions/vibeterm-telemetry/` receives telemetry via the OpenClaw gateway

These plugins are optional for core ClawGate development, but if you touch them, run the Node-based tests too.

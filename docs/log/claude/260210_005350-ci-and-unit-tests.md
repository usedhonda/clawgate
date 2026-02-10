# GitHub Actions CI + Unit Test Expansion

**Date**: 2026-02-10
**Branch**: feat/tmux-adapter
**PR**: https://github.com/usedhonda/clawgate/pull/1

## What was done

### 1. GitHub Actions CI (.github/workflows/ci.yml)
- **swift-test job** (macos-15): Xcode 16, swift build + swift test, SPM cache
- **lint job** (ubuntu-latest): shellcheck + node --check on JS files
- Triggers: PR to main, push to main
- Concurrency with cancel-in-progress

### 2. BridgeCoreTests compile fix
- Added missing `configStore: cfg` argument to `makeCore()` and `makeCoreWithFailingAdapter()`
- File: Tests/UnitTests/BridgeCoreTests.swift:214,227

### 3. TmuxInboundWatcher access level change
- `detectQuestion(from:)`: private -> internal
- `extractSummary(from:)`: private -> internal
- Enables @testable import access for unit tests

### 4. New unit tests (4 files, ~28 tests)
- **TmuxOutputParserTests.swift**: 10 tests for detectQuestion/extractSummary
- **RecentSendTrackerTests.swift**: 6 tests including thread safety
- **ConfigStoreTests.swift**: 7 tests including migration verification
- **RetryPolicyTests.swift**: 5 tests for retry logic

### 5. Shellcheck fixes
- Removed unused `SSE_OUTPUT` variable (integration-test.sh)
- Replaced `A && B || C` with if/else (setup-cert.sh)
- Removed unused `YELLOW` color variable (smoke-test.sh)

### 6. Branch protection
- Required status check: `swift-test` on main

## CI Results
- lint: PASS (5s)
- swift-test: PASS (1m35s)
- Cost estimate: ~$0.16/PR (macOS runner)

## Files changed
| File | Change |
|------|--------|
| .github/workflows/ci.yml | NEW - CI workflow |
| Tests/UnitTests/BridgeCoreTests.swift | Fix configStore: argument |
| ClawGate/Adapters/Tmux/TmuxInboundWatcher.swift | private -> internal (2 methods) |
| Tests/UnitTests/TmuxOutputParserTests.swift | NEW - 10 tests |
| Tests/UnitTests/RecentSendTrackerTests.swift | NEW - 6 tests |
| Tests/UnitTests/ConfigStoreTests.swift | NEW - 7 tests |
| Tests/UnitTests/RetryPolicyTests.swift | NEW - 5 tests |
| scripts/integration-test.sh | Remove unused variable |
| scripts/setup-cert.sh | Fix shellcheck SC2015 |
| scripts/smoke-test.sh | Remove unused variable |

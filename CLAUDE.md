# ClawGate - CLAUDE.md

macOS menubar app that bridges local AI agents to native apps via Accessibility API.

**IMPORTANT**: After context refresh (compression), always read `SPEC.md` first
to restore full technical specification knowledge before making changes.

---

## AI-Autonomous Development

**Core principle: AI completes every step. Human involvement is a last resort.**

Do not ask the user to confirm, verify, launch, or test anything that AI can do itself.
Every operation below has a concrete command — use it.

### Never Re-Ask Rule

**Once-confirmed information MUST be persisted to files and NEVER asked again.**
Test parameters, conversation hints, environment details — all go in `docs/testing.md`.
After context refresh, read `docs/testing.md` to restore parameters. Do NOT ask the user.
"Context refresh" is never an excuse to re-ask something already documented.

### Self-Service Operations

| Operation | AI Command | NEVER say this |
|-----------|-----------|----------------|
| See screen state | `screencapture -x -D1 /tmp/clawgate-screen.png` → Read the image | "Can you check the screen?" |
| Inspect AX tree | `curl -s -H "X-Bridge-Token: $TOKEN" localhost:8765/v1/axdump \| jq .` | "Can you look at the AX tree?" |
| Check AX permission | `curl -s -H "X-Bridge-Token: $TOKEN" localhost:8765/v1/doctor` — poll until ok | "Do you have AX permission?" |
| Restart app | `pkill -f ClawGate.app; sleep 1; open ClawGate.app` | "Please restart the app" |
| Build + deploy | `swift build && pkill -f ClawGate.app; sleep 1 && cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate && codesign --force --deep --options runtime --entitlements ClawGate.entitlements --sign "ClawGate Dev" ClawGate.app && open ClawGate.app` | Stopping after build to ask user |
| Test via API | `curl -s -X POST -H "X-Bridge-Token: $TOKEN" -d '...' localhost:8765/v1/send` | "Can you test this?" |
| Verify result | Screenshot + axdump + messages API — AI reads all and judges | "Did it work?" |
| Run integration tests | `./scripts/integration-test.sh` | "Please run the tests" |
| Get pairing token | `curl -s -X POST localhost:8765/v1/pair/generate` then `curl -s -X POST -d '{"code":"..."}' localhost:8765/v1/pair/request` | "Please pair the client" |

### Build-Deploy Pipeline (mandatory after code changes)

Always run the full pipeline in one shot — never stop partway:

```bash
swift build \
  && pkill -f ClawGate.app; sleep 1 \
  && cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate \
  && codesign --force --deep --options runtime \
       --entitlements ClawGate.entitlements --sign "ClawGate Dev" ClawGate.app \
  && open ClawGate.app
```

**CRITICAL**: Always sign with `--sign "ClawGate Dev"` (self-signed cert), NOT `--sign -` (ad-hoc).
Ad-hoc signing produces a different CDHash each time, which invalidates the TCC AX permission entry.
The "ClawGate Dev" cert produces a stable CDHash, so AX permission persists across rebuilds.

### Human Intervention Required (exhaustive list)

Only these operations genuinely require human action:

| Operation | Why |
|-----------|-----|
| AX permission initial grant | System Settings GUI — macOS security policy, cannot be automated |
| AX permission toggle OFF→ON | When CDHash changes after re-sign — user toggles in System Settings |
| LINE app installation | First-time setup only |

**`tccutil reset` is permanently banned.** It deletes the entire TCC entry, forcing the user
to re-add ClawGate from scratch. When AX permission is stale, restart the app and ask the
user to toggle OFF→ON — never reset.

---

## Debug Workflow

Every step uses AI tools — no human involvement:

```
1. screencapture -x -D1 /tmp/clawgate-before.png → Read (AI sees full display)
2. curl /v1/axdump                               → AI inspects AX tree
3. State facts: what IS happening (with evidence)
4. State hypothesis: what MIGHT be the cause (clearly labeled)
5. Implement minimal fix (smallest possible change)
6. Build → kill → cp → re-sign → open           (full pipeline, one shot)
7. curl /v1/send or appropriate API              → test the change
8. screencapture -x -D1 /tmp/clawgate-after.png → Read (AI sees full display)
9. Compare before/after → decide: fix worked or revise hypothesis
```

### Rules

- **Fact vs Hypothesis**: Always separate observed behavior (with evidence) from guesses.
  Never start coding based on a guess alone.
- **Observe first**: Before changing code, capture screen + AX tree to understand current state.
- **Minimal change**: Fix only what's broken. Do not rewrite surrounding code.
- **Verify with evidence**: A fix is confirmed only when screenshot + API response both show
  the expected behavior. "It compiled" is not verification.
- **Self-verify**: AI MUST judge test results using axdump, messages API, and screenshots.
  NEVER ask the user "did it work?" or "was the message sent?". Use tools to determine the answer.
- **Screenshots**: Always use `screencapture -x -D1` (full display 1). Never use bare `-x`
  which may capture only the focused window or miss the target app entirely.

---

## Quick Reference

```
swift build                              # Debug build
./scripts/integration-test.sh            # Run 24 integration tests (auto-pairs)
./scripts/release.sh                     # Build + sign + DMG + notarize
```

After updating binary:
```
cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
codesign --force --deep --options runtime --entitlements ClawGate.entitlements --sign "ClawGate Dev" ClawGate.app
```

## Key Files

- `SPEC.md` — Full technical specification (API, threading, auth, models, selectors)
- `AGENTS.md` — Product requirements and design goals
- `docs/architecture.md` — Architecture overview
- `docs/troubleshooting.md` — Known issues and fixes
- `docs/testing.md` — **Test parameters (conversation_hint, text, etc.) — NEVER re-ask the user**

---

## Common Pitfalls

### Threading (NIO + BlockingWork)

- **Never block NIO event loop.** All AX queries, Keychain writes, and adapter calls go
  through `BlockingWork.queue`.
- **Keychain writes are fire-and-forget.** Use `DispatchQueue.global(qos: .utility).async`
  for `keychain.save()`. Ad-hoc signed apps trigger a blocking macOS dialog on Keychain
  access, which freezes `BlockingWork.queue` entirely.
- Token auth uses in-memory cache — never reads Keychain at runtime.

### AX / Qt (LINE)

- **`sendEnter(pid:)` uses AXPostKeyboardEvent only** (direct to PID via dlsym).
  CGEvent strategies were removed — they interfere with Qt window focus.
  Use `setFocused(element)` + `app.activate()` before `sendEnter`, not `clickAt`.
- **`AXUIElementPostKeyboardEvent` is unavailable in Swift** (deprecated since macOS 10.9).
  Access via `dlsym(dlopen(nil, RTLD_LAZY), "AXUIElementPostKeyboardEvent")`.
  Do NOT add C bridging modules — dlsym keeps Package.swift simple.
- **CGEvent tap levels matter**: `.cghidEventTap` (HID layer) works with Qt search;
  `.cgSessionEventTap` (session layer) is ignored by Qt.
- **LINE background**: AXWindow count = 0 (only AXMenuBar). Use `kAEReopenApplication`
  to create window, not just `activate()`.

### Build

- **`swift test` requires full Xcode** (not just CommandLineTools).
- **After binary update**, always re-sign the app bundle (see Quick Reference).

---

## Language Rules

- **All externally visible content must be in English**: UI strings, API error messages,
  menu labels, settings, commit messages, CLAUDE.md, SPEC.md, AGENTS.md, README, etc.
- **Internal development is in Japanese**: work logs (`docs/log/`), plan files (`plans/`),
  code comments (optional), and Claude Code conversations.
- **Exception**: Regex patterns that match Japanese UI text (e.g. LINE's weekday names)
  are internal logic, not user-facing, and may contain Japanese.

## Conventions

- **Work logs**: `docs/log/claude/YYMMDD_HHMMSS-description.md`
- **Plans**: `plans/` (auto-generated by Claude Code plan mode)
- **No `.local/` in git** (secrets, .gitignore'd)
- **Commits**: English, prefixed: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`
- **No `Co-Authored-By: Claude` lines**

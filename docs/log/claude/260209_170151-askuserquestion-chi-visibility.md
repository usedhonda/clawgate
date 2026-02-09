# AskUserQuestion visibility for Chi

## Task
Make Claude Code's AskUserQuestion selection menus visible to Chi (OpenClaw AI agent) so Chi can read and answer them.

## Changes

### 1. TmuxInboundWatcher.swift
- Added `DetectedQuestion` struct (questionText, options, selectedIndex, questionID)
- Added `detectQuestion(from:)` method with multi-layer detection:
  - Scans from bottom of capture-pane output
  - Detects option lines with `>` (U+276F), `*` (U+25CF) selectors or `?` (U+25CB) bullets
  - Finds question text (line ending with `?`)
  - Requires at least 2 options
- Modified `captureAndEmit()`:
  - Increased capture lines from 30 to 50
  - Added 200ms render delay before capture
  - Emits `source: "question"` with structured fields (question_text, question_options, question_selected, question_id)
  - Falls back to `source: "completion"` for non-question state changes

### 2. TmuxAdapter.swift
- Added `__cc_select:N` prefix detection in `sendMessage()`
- Added `sendMenuSelect(target:optionIndex:)` method:
  - Smart mode: captures pane, detects current selection, sends minimal Up/Down keys
  - Fallback: Up x20 (go to top) + Down x N
  - 50ms delay between keys, Enter to confirm

### 3. gateway.js (OpenClaw plugin)
- Added `pendingQuestions` Map tracking active questions per project
- Added `handleTmuxQuestion()`: formats question + numbered options for Chi, instructs `<cc_answer>` usage
- Added `tryExtractAndSendAnswer()`: parses `<cc_answer project="name">{N}</cc_answer>`, sends `__cc_select:N`
- Added question event routing in polling loop (`source === "question"`)
- Added `<cc_answer>` parsing in `handleInboundMessage` deliver callback (LINE replies)
- `handleTmuxCompletion` clears pending questions
- `buildRosterPrefix` passes `pendingQuestions` to roster builder

### 4. context-reader.js
- `buildProjectRoster()` now accepts `pendingQuestion` field on projects
- Shows `[ASKING: question preview]` indicator in roster

### 5. context-cache.js
- `getProjectRoster()` accepts optional `pendingQuestions` parameter

### 6. claude-code-knowledge.md
- Documented `<cc_answer>` tag usage for Chi
- Explained priority: answer pending questions before sending new tasks

## Data Flow
```
CC AskUserQuestion -> cc-status-bar: waiting_input
-> TmuxInboundWatcher: 200ms wait, capture 50 lines, detectQuestion()
-> EventBus: source="question" + structured fields
-> gateway.js: handleTmuxQuestion() -> Chi sees question + options
-> Chi: <cc_answer project="x">2</cc_answer>
-> tryExtractAndSendAnswer() -> clawgateTmuxSend("__cc_select:1")
-> TmuxAdapter.sendMenuSelect() -> Up/Down + Enter in tmux
-> CC: option selected
```

## Verification
- Build: OK
- Smoke test: S1-S4 PASS, S5 timing race (gateway restart)
- OpenClaw doctor: 14/14 PASS

# Autonomous CC Task Routing via `<cc_task>` Tags

**Date**: 2026-02-09
**Branch**: `feat/tmux-adapter`

## Summary

Implemented the mechanism for Chi (AI) to send follow-up tasks to Claude Code
in autonomous mode. When the AI reply contains `<cc_task>...</cc_task>` tags,
the tagged content is extracted and sent to Claude Code via `clawgateTmuxSend()`,
while the remaining text goes to LINE.

## Changes

### `extensions/openclaw-plugin/src/gateway.js`

1. **`tryExtractAndSendTask()`** — shared helper function
   - Parses `<cc_task>` from AI reply text
   - Sends task via `clawgateTmuxSend()`
   - Returns `{ lineText, taskText }` on success, `{ error, lineText }` on failure, `null` if no tag
   - Checks consecutive task chain limit (MAX_CONSECUTIVE_TASKS = 5)

2. **`resetTaskChain()`** — resets counter for a project

3. **`consecutiveTaskCount`** — Map tracking per-project chain count
   - Incremented on each successful task send
   - Reset when: human sends LINE message, AI replies without `<cc_task>`, or limit reached

4. **`handleTmuxCompletion()` deliver** — autonomous mode routing
   - Calls `tryExtractAndSendTask()` when mode === "autonomous"
   - On success: task -> CC, lineText -> LINE
   - On error: full reply + error notice -> LINE
   - No tag found: reset chain, forward all to LINE

5. **`handleTmuxCompletion()` taskSummary** — autonomous prefix
   - Instructs AI about `<cc_task>` tag usage
   - Shows chain count and remaining quota

6. **`handleInboundMessage()` deliver** — LINE -> CC routing
   - Finds autonomous projects from sessionModes
   - If AI reply contains `<cc_task>`, sends to first autonomous project
   - Human input resets all task chain counters

7. **`buildRosterPrefix()`** — task hint for LINE messages
   - When autonomous projects exist, adds `<cc_task>` usage hint to roster prefix

### `extensions/openclaw-plugin/claude-code-knowledge.md`

- Updated modes description to include `<cc_task>` tag usage
- Added chain limit documentation

## Safety Mechanisms

| Mechanism | Description |
|-----------|-------------|
| Chain limit (5) | Maximum consecutive tasks without human input |
| MenuBar toggle | Switch autonomous -> observe to stop immediately |
| Session kill | Kill tmux session to terminate |
| Chain reset | Human LINE message resets all counters |
| No-tag reset | AI reply without `<cc_task>` resets counter |
| Error reporting | Task send failures reported to LINE |

## Deploy

- `dev-deploy.sh` full pipeline: PASS (5/5 smoke tests)
- Build: OK, Plugin sync: OK, Gateway restart: OK

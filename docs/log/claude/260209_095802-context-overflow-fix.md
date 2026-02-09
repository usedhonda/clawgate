# Fix: Context Overflow — OpenClaw Image Path Sanitization

## Problem

Chi sent "Context overflow: prompt too large for the model" errors to LINE.

Root cause chain:
1. CLAUDE.md contains image paths like `/tmp/clawgate-screen.png`
2. context-reader.js reads CLAUDE.md into projectContext
3. OpenClaw's `detectImageReferences()` finds `.png` paths in text
4. Embeds `/tmp/clawgate-screen.png` (14MB) as base64 in every message
5. 7 tmux completions accumulate ~35MB -> Claude Sonnet 4.5 context limit exceeded

## Fix

### context-reader.js
- Added `IMAGE_PATH_PATTERN` regex for common image extensions
- Added `sanitizeImagePaths()` — replaces `/path/to/file.png` with `<file.png>`
- Applied to `buildProjectContext()` output before returning

### Cleanup
- Deleted `/tmp/clawgate-screen.png` (14MB leftover screenshot)

## Changed Files
- `extensions/openclaw-plugin/src/context-reader.js:12-27` — sanitize function
- `extensions/openclaw-plugin/src/context-reader.js:146` — apply to output

## Verification
- `buildProjectContext()` output: 0 raw PNG paths, 1 sanitized placeholder `<clawgate-screen.png>`
- OpenClaw doctor: 14/14 PASS
- Smoke test: S1-S4 PASS, S5 recovered after gateway restart delay

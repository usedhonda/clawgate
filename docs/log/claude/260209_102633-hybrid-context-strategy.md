# Hybrid Context Strategy Implementation

## Date: 2026-02-09

## Summary

Implemented two-layer context management (Stable + Dynamic) for tmux completion events
to solve context overflow and information gap issues.

## Problem

1. **Context overflow**: ~8000 chars per tmux completion, 5 chains = ~35KB overflow
2. **Information gap**: context-reader only read CLAUDE.md/AGENTS.md/README.md,
   missing SPEC.md, docs/testing.md etc. that CLAUDE.md references

## Solution

### Two-layer context

| Layer | Content | Size | When sent |
|-------|---------|------|-----------|
| Stable | CLAUDE.md + detected refs (SPEC.md, docs/testing.md, etc.) + CC knowledge | ~12K | First time or hash change |
| Dynamic | git branch, 3 commits, 2 work logs | ~1K | Every time |

**Result**: 5 chains = ~12K + 4x~1K = ~16K (vs ~35K before, 54% reduction with MORE info)

### Dynamic reference detection (`extractReferencedFiles`)

Parses CLAUDE.md for three patterns:
- Key Files bullets: `- \`SPEC.md\` — description`
- Read-first: `read \`SPEC.md\` first`
- Persistence: `go in \`docs/testing.md\``

Detected for clawgate: SPEC.md, AGENTS.md, docs/architecture.md, docs/troubleshooting.md, docs/testing.md

### Smart truncation

When files exceed budget, headings and IMPORTANT/CRITICAL/NEVER/MUST lines are prioritized.

## Changed Files

- `extensions/openclaw-plugin/src/context-reader.js` — New functions: extractReferencedFiles, smartTruncate, buildStableContext, buildDynamicEnvelope. Constants: MAX_STABLE_CHARS=12000, MAX_ENVELOPE_CHARS=1500, MAX_FILE_CHARS=4000
- `extensions/openclaw-plugin/src/context-cache.js` — New: sentHash Map, getStableContext(), getDynamicEnvelope(), markContextSent()
- `extensions/openclaw-plugin/src/gateway.js` — handleTmuxCompletion uses 2-layer context with hash-based dedup

## Verification

- buildStableContext: 12,038 chars, includes SPEC.md + testing.md
- buildDynamicEnvelope: 1,009 chars
- Image paths sanitized (no PNG paths in output)
- dev-deploy.sh: build OK, deploy OK, gateway restart OK
- OpenClaw: doctor OK (5/5), initial cursor=0

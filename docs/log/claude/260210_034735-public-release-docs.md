# Documentation Update for Public Release

**Date**: 2026-02-10
**Branch**: research/codex-line-detection

## Summary

Major documentation overhaul to bring docs up to date with the current codebase state.

## Changes

### New Files
- **README.md**: Project entry point for GitHub (~190 lines)
  - CI badge, architecture diagram, API overview table, quick start guide
  - Project structure, configuration reference, links to SPEC.md

### Rewritten Files
- **docs/architecture.md**: Complete rewrite
  - Removed all references to AppBridge, BridgeTokenManager, X-Bridge-Token
  - Added: TmuxAdapter, NotificationBannerWatcher, FusionEngine, echo suppression, extensions
  - Updated API surface (10 endpoints), threading model (added CCStatusBarClient + Main RunLoop)

### Updated Files
- **SPEC.md**: Extensive updates across 8 sections
  - Section 1: "LINE as first adapter" -> "LINE and tmux adapters"; signing: "Ad-hoc" -> "ClawGate Dev"
  - Section 2: Added 20+ missing files/directories (Tmux/, Detection/, Vision/, extensions/, scripts/, tests)
  - Section 5: Added /v1/config endpoint; added 7 tmux error codes
  - Section 6: Added LINEAdapter + TmuxAdapter subsections with detailed behavior
  - Section 7: Complete rewrite - EventBus, 5 event types, echo suppression, NotificationBannerWatcher, LINEInboundWatcher, FusionEngine, detection config
  - New Section 8: Tmux Integration (CCStatusBarClient, TmuxShell, TmuxInboundWatcher, session modes, menu bar)
  - Section 10 (was 9): Fixed signing, added dev-deploy.sh, smoke-test.sh, CI note
  - Section 12 (was 11): Updated test count (18), added unit test file list (8 files)
  - Renumbered sections 9-13 after Tmux section insertion

## Verification
- No references to AppBridge, X-Bridge-Token, or BridgeTokenManager
- No internal paths (.claude/, .local/, MEMORY.md)
- No Japanese text in any updated file
- All 10 endpoints documented (matching BridgeRequestHandler route table)
- Section numbering: 1-13 consecutive
- Smoke test: 4/4 PASS

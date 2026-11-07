# Incremental test consolidation — 2026-11-07

## Scope and baseline

This change reuses the [2026-10-22 test-value audit](../audits/test-value-audit.md)
and revalidates its consolidation candidates against ClawGate main
`1174c9b78a74fab56d5a8c710a7ee613ad792cb6`. It does not repeat that audit or
claim that every old finding still applies unchanged.

Only eight test files and this report change. Production code, fixtures, package
dependencies, CI jobs, and opt-in conditions are unchanged. The separate bridge,
browser, and OpenClaw repairs are in PR #8; this branch is independently based on
main and does not include those changes.

## Inventory and counts

Counts below are test declarations, not input-vector or assertion counts.
The Swift inventory contains 148 files, including the case-free
`MinutesPreparationTestSupport.swift`. The JavaScript inventory contains
19 OpenClaw-plugin and seven Chrome-extension test files. Those file counts and
the three shared JSON fixtures are unchanged.

| Surface | Before | After | Net |
| --- | ---: | ---: | ---: |
| Swift test methods | 1,207 | 1,196 | -11 |
| OpenClaw plugin cases | 190 | 184 | -6 |
| Chrome extension cases | 47 | 47 | 0 |
| Total Swift + JavaScript declarations | 1,444 | 1,427 | **-17** |
| Test source files | 174 | 174 | 0 |

At the declaration/name level, this change adds three replacement Swift method
names and removes 14 superseded Swift names; JavaScript adds none and removes
six. The three replacement names consolidate or rename existing contracts;
there are no additional standalone test scenarios or test files. The panel
truth table gains its previously unlisted `visible=false, key=false` row.

| Changed test file | Before | After |
| --- | ---: | ---: |
| `AmbientTests.swift` | 79 | 77 |
| `LINEAdapterTests.swift` | 19 | 14 |
| `LineTextSanitizerTests.swift` | 3 | 3 |
| `MenuBarRevealTests.swift` | 3 | 1 |
| `RecentSendTrackerTests.swift` | 10 | 9 |
| `RuntimeRoleTests.swift` | 10 | 10 |
| `VisionOCRChromeLabelTests.swift` | 15 | 14 |
| `outbound.test.js` | 29 | 23 |

## Removal and retention map

The F identifiers refer to the existing
[findings ledger](../audits/test-value-findings.md). They are evidence references,
not automatic permission to delete a test.

### F14: panel reveal policy

The three old `MenuBarRevealTests` methods called the same pure policy and
contained two duplicate evaluations: visible/key was asserted twice, and
visible/non-key appeared in two methods. None drove an activation event.

`testOnlyVisibleKeyPanelCloses` now lists each of the four Boolean combinations
once and prints the failing input pair. Every previously distinct input remains.
This is a policy test; it does not claim to exercise actual AppKit activation.

### F15: LINE helper tests belong with their helper

Five `LINEAdapterTests` methods did not invoke the adapter:

| Removed method | Retained protection |
| --- | --- |
| `testEchoDetectionForLINESentText` | `RecentSendTrackerTests.testRecordedSendIsAvailableForEchoDetection` retains the 60-second tracker, prefixed multiline text, echo result, and returned text. The default tracker and original plain-text case are also retained. |
| `testEchoDetectionWithLineBreaksInBubble` | `LineTextSanitizerTests.testEchoNormalizationMatchesAcrossWhitespace` retains the exact prefixed/reflowed text pair. The unused tracker setup is gone. |
| `testSanitizeRemovesUIArtifactsFromSearchResult` | `testSanitizeRemovesStandaloneUIArtifacts` retains both the English and Japanese body inputs after the same read receipt and timestamp. |
| `testSanitizePreservesLongMessageWithTimestampWord` | `testSanitizeKeepsLongMessage` retains the exact long sentence with an embedded time and read-receipt word. |
| `testRecentSendTrackerRecordsConversation` | `RecentSendTrackerTests.testRecentSentTextReturnsNewest` retains the two-conversation sequence alongside its original three-send sequence, checking the newest value after each send. |

The tracker suite's separate single-send echo and text-return tests are also
combined into `testRecordedSendIsAvailableForEchoDetection`. Empty-history,
expiry, concurrent-access, text-match, and insufficient-signal tests remain.

The removed caching comment described an adapter send-success contract that the
helper test never exercised. This change does not claim new coverage of that
navigation-cache contract.

### F16: outbound cases with identical setup and stronger retained assertions

These tests call the real `outbound.sendText` implementation with transport,
configuration, state, and semantic-audio boundaries mocked. Each removed case
has the same input and stub state as its retained case:

| Removed case | Retained case / added assertion |
| --- | --- |
| `observe tmux sessionKey stays on LINE, NOT pane` | `observe stays on LINE and is NOT prefixed (no pane redirect)` already checks the same route plus unmodified text and no queue. |
| `non-tmux sessionKey stays on LINE regardless of mode` | `non-tmux sessionKey stays on LINE unprefixed regardless of mode` already checks those assertions plus text and no queue. |
| `no sessionKey stays on LINE (secretary/normal conversation unchanged)` | The sendText `maps to="LINE" to defaultConversation` case now also checks no tmux send. |
| Autonomous prefix-only case | The autonomous tmux routing case already asserts the identical prefix. |
| Auto prefix-only case | The auto tmux routing case now asserts that prefix alongside project and no LINE send. |
| `ok tmux send returns success shape with tmux message_id (no queue)` | The autonomous tmux routing case now asserts the same returned channel, message ID, chat ID, and empty queue. |

Text and media entry points remain separately covered. The three retriable
error-code cases, non-retriable failure, media queuing, return-URL delivery, and
protected admission/audio boundaries remain separate. They exercise distinct
failure modes or entry points and were not collapsed to reduce a number.

### F17: runtime-role characterization

`AmbientTests.testRuntimeRoleFromGatewayRelationship` duplicated the dedicated
runtime-role suite. The default-configuration assertions move into
`testDefaultAndEmptyHostResolveToServer`; the placeholder remote-host vector
joins `testRemoteHostsResolveToClient`. All of the original loopback inputs
were already in the dedicated suite. Trimming, case, IPv6, port suffixes,
subdomain confusion, and persisted-role precedence checks remain.

### F18: identical parser rejection

`testResultParserRejectsMiddleSubsetEvenWithHighBoundaryConfidence` used the
same helper arguments, allowed segment order, selection mode, and expected
failure as the negative half of
`testResultParserAutomaticAcceptsBackwardSuffixRejectsMiddleSubset`.
The latter remains, including both the accepted suffix and rejected middle
subset and the historical explanation. Other parser failures are untouched.

### F19: mislabeled positioned helper test

`testPositionedChromeFilterKeepsMessageSemantics` only called
`VisionOCR.isChromeLabel`; it supplied no position. Its two exact strings move
into the timestamp and sentence helper tests. The actual bounding-box mapping
test and whole-frame ordering/filtering tests remain.

## Validation and limits

- **Passed before the execution environment disconnected:** the changed
  outbound file, 23/23 tests on Node.js 24.22.1. One run reported 114.451 ms;
  this is not a before/after performance benchmark.
- **Passed by source inspection:** removal-to-retention mapping, before/after
  declaration counts, preservation of distinct boundary inputs, and no trailing
  whitespace in the reconstructed files.
- **Not run locally:** full 184-case plugin suite, mutation probes, and Swift
  tests. The queued full-suite/mutation commands failed to start when the
  execution environment disconnected. They produced no test results.
- **CI:** the exact-head PR result is the build and full-suite evidence. See
  the PR checks for its final status; no locally executed Swift result is claimed.
- No production app, live message, Gateway, audio service, signing, or deployment
  operation was performed.

After the environment disconnected, the same eight-file patch was reconstructed
from immutable baseline files using unique source anchors. Per-file additions,
deletions, and case counts matched the earlier local diff: 74 inserted and
197 removed test-source lines. The reconstruction is therefore reviewable
against the same baseline; CI remains necessary.

The maintained benefit is one clear home for each repeated contract and fewer
case setups. There is no measured CPU, battery, end-to-end latency, or CI-time
improvement claimed for these source-test changes.

## Related findings kept separate

F27's LINE smoke job repeats a Swift subset on a second macOS runner and
repeats outbound tests already included in the full plugin suite. Its workflow
change is coordinated with PR #8, which already owns CI coverage changes;
this independent test branch does not edit the workflow. Preserve the existing
check name as a dependency gate if branch rules refer to it, and require the
full Swift and plugin jobs to succeed.

Weak or copied tests in F01, F03, and F04 are not removed here: an equivalent
production-consumer test has not been established for every contract.
Static privacy/API guards, acknowledgement persistence at distinct layers,
expiry boundaries, and opt-in real-service tests also remain. These distinctions
prevent a lower test count from being misreported as proof of equal coverage.

## Model/API scope

No production model ID, provider endpoint, SDK, API family, or runtime version
changes in this test-only PR. The repository's OpenClaw/provider compatibility
review is separate; this is not a claim that ClawGate has no AI integration.

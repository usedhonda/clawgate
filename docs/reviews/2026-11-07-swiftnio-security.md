# SwiftNIO dependency security review

Reviewed 2026-11-07 against ClawGate main
`1174c9b78a74fab56d5a8c710a7ee613ad792cb6`.

## Finding and affected boundary

The application resolved SwiftNIO **2.94.0**, while its manifest allowed versions
as old as 2.67.0. The upstream advisories below include that resolved version:

| Upstream advisory | Fixed version | Relevance to ClawGate |
| --- | --- | --- |
| [Unbounded aggregate HTTP headers, CVE-2026-28980](https://github.com/apple/swift-nio/security/advisories/GHSA-rj37-6j9x-74q6) | 2.100.0 | The bridge installs the default NIO HTTP server pipeline. Decoding happens before application Host, Origin, source-address, and body checks. |
| [WebSocket length conversion trap, CVE-2026-43678](https://github.com/apple/swift-nio/security/advisories/GHSA-qcc5-f287-vgmq) | 2.101.0 | The federation upgrade installs NIOWebSocket. Reachability depends on that feature and its admission policy; an accepted peer's frame still needs safe decoding. |
| [Outbound start-line validation, CVE-2026-28970](https://github.com/advisories/GHSA-cq87-8r7h-962v) | 2.100.0 | Included in the vulnerable dependency. No attacker-controlled outbound start-line exploit was established in this review. |

The application-level hardening in PR #8 complements this dependency update.
It cannot repair parser behavior that occurs before the application's handler.
No live service was attacked and no production crash was induced.

## Change and compatibility

Raise the manifest's lower bound and the resolved pin to **2.101.3**, upstream
commit `0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b`. This includes the fixes above
and the subsequent HTTP header-limit compatibility correction in
[2.101.3](https://github.com/apple/swift-nio/releases/tag/2.101.3).
The reviewed tagged decoder defaults cap the aggregate header block at 80 KiB.
The newer 2.105.0 release was also checked; this focused repair selects the
smaller release baseline containing the required security fixes.

SwiftNIO's 2.101.3 manifest requires Swift 6.1 or newer, which is satisfied by
the repository's Xcode 26.3 CI toolchain. ClawGate retains its existing Swift
language mode and macOS deployment target. Other resolved packages remain
unchanged and satisfy this tag's declared dependency ranges. CI must validate
resolution and application compatibility; editing a pin alone is not a build.

## Test intent and validation

Existing bridge tests exercise application routing and admission, not raw NIO
decoding. Two focused cases cover the missing boundary: bounded aggregate HTTP
headers made from individually small fields, and graceful rejection of a
WebSocket length that cannot be represented as an Int. They use embedded
channels and do not open sockets. Tests added: 2; removed: 0; consolidated: 0.
These do not duplicate upstream's full parser suite.

The PR records the exact-commit macOS build and full-suite CI outcome. The
editing environment had no Swift toolchain and then became unavailable; the
patch was recovered through immutable GitHub source reads. New tests were not
run against the known-vulnerable version because one upstream failure terminates
the test process. The affected-version evidence comes from the official
advisories and the resolved lockfile, not a claimed local exploit demonstration.

This dependency change does not alter provider models, OpenClaw dispatch,
credentials, signing, release, or deployment. Reverting both manifest and lockfile
would reintroduce the affected parser dependency; use a newer compatible patched
release if this baseline needs replacement.

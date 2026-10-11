# AX wait policy

ClawGate's window recovery path performs AppKit/Accessibility work from
polling and worker queues, while Apple Events and activation must run on the
main queue. These crossings are bounded:

- Main-queue reopen/activate callbacks wait at most `AXActions.mainCallbackTimeout`
  (2.5 seconds).
- A callback that is still queued when its wait expires is fenced and performs
  no AX/AppKit side effect. A callback already executing is allowed to finish
  its own bounded operation.
- The `osascript` fallback created by `sendReopenEvent` waits at most
  `AXActions.reopenFallbackTimeout` (2 seconds). On expiry only that child is
  terminated; no unrelated process is touched.

After a timeout, `ensureWindow` returns failure and its caller may retry through
the normal tracking/recovery path. The existing AX polling deadlines remain
unchanged, preserving LINE's established window behavior while preventing an
unbounded main-thread wait.

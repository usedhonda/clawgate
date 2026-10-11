# AX wait policy

ClawGate's window recovery path performs AppKit/Accessibility work from
polling and worker queues, while Apple Events and activation must run on the
main queue. These crossings are bounded:

- Main-queue reopen/activate callbacks wait at most `AXActions.mainCallbackTimeout`
  (2.5 seconds).
- A callback that is still queued when its wait expires is fenced and performs
  no AX/AppKit side effect. A callback already executing is allowed to finish
  its own bounded operation; the fence cannot revoke an in-flight callback.
- The `osascript` fallback created by `sendReopenEvent` waits at most
  `AXActions.reopenFallbackTimeout` (2 seconds). On expiry only that child is
  asked to terminate; this bounds ClawGate's wait but does not claim that the
  child has exited synchronously.
- Pet window tracking applies the same AX messaging timeout to its application
  and candidate window elements before synchronous reads. Each tracking probe
  has a 250ms aggregate budget and examines at most eight candidates; if the
  budget expires, placement falls back to the already-collected CG window
  frame, preventing a wedged target app from blocking a tracking tick
  indefinitely. The two-message frame read (position then size) checks the
  remaining budget before each AX message, so size is not issued after the
  position read consumes the deadline.

After a timeout, `ensureWindow` returns failure and its caller may retry through
the normal tracking/recovery path. The existing AX polling deadlines remain
unchanged, preserving LINE's established window behavior while preventing an
unbounded main-thread wait.

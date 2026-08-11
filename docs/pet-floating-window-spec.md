# Pet Floating Window Contract

## Scope

This document is the Normative contract for the Pet floating chat experience only:

- full-chat window creation and lifecycle behavior
- menu-bar left-click reveal routing for settings + chat
- z-order and activation rules
- close/reveal edge behavior and non-visible/no-op behavior

## Normative (shipped)

### Geometry contract

- All pet windows (chat, notification, ask, summon menu, whisper) use a shared
  geometry contract that:
  - chooses visibility target in this order:
    1. parent `screen` visible frame when available
    2. any screen whose visible frame intersects the parent window frame
    3. main visible frame as typed fallback
- selection returns `.some(visibleFrame)` or `.none` when no screen target exists
- uses a common clamp path that can shrink oversize windows to fit the visible frame
- keeps pet character windows square by clamping content size to
  `min(requested, visible.width-20, visible.height-20)` and adding 20-point chrome
  before window sizing
- applies minimum-size floors when clamping so geometry is still valid
- keeps resize anchors stable for content-initiated resizes (center-anchor behavior)
- keeps every visible frame inside the selected visible frame even when content
  grows after initial render
- avoids assumptions about `NSScreen.screens[0]`; no force unwrap when target lists are empty
- when no target screen exists, character creation skips and content-driven resizes use an
  explicit local safe fallback; child-window placement preserves its local frame

### Activation and focus

- `showFullChat()` must create the full chat window as an activating macOS window.
- `showFullChat()` must use:
  - `PetChatWindowPolicy.chatWindowStyleMask` for window style
  - `PetChatWindowPolicy.chatWindowCollectionBehavior` for collection rules
- Style mask must include `titled`, `resizable`, `fullSizeContentView`, and `closable`.
- `nonactivatingPanel` must NOT be in the full-chat style mask.
- Standard close control must be visible and functional.
- The chat window must keep `KeyableWindow` behavior so it can become key/main.
- Bringing to front from the menu bar path must:
  - force activation with `NSApp.activate(ignoringOtherApps: true)`
  - call `cw.makeKeyAndOrderFront(nil)`
  - keep chat in active Space movement via `PetChatWindowPolicy.chatWindowCollectionBehavior`
- Main-menu close control must expose standard semantics through a menu item that sends
  `performClose(_:)` with `Cmd+W` so key-window close dispatch follows first-responder chain.

### Clipboard ownership

- Every ClawGate clipboard write, temporary AX/Pet paste, and conditional restore registers
  the resulting `NSPasteboard.changeCount` as an owned transaction.
- The watcher consumes each owned change count once without emitting a clipboard offer; a
  genuine user change count emits at most one offer.
- Temporary clipboard restoration is conditional on the pasteboard still having the exact
  owned change count. If the user copies during the temporary write, the user's clipboard is
  preserved and the restore is skipped.
- Starting or stopping the watcher clears stale owned and observed transaction state.

### Z-order and Space behavior

- The full chat must use normal level (`.normal`) so it is not pinned above all apps.
- It must naturally fall behind other apps when they become active.
- Menu-bar left-click reveal may only touch an existing chat window instance.
- Existing chat reveal must skip if not visible or if minimized.
- Existing chat reveal from menu-bar left-click must surface a visible chat onto the active app front.
- No synthetic reveal path may run if the chat window is already closed or hidden.

### Close and reveal behavior

- Close path must use standard window close semantics:
  - close button should close the full chat
  - `performClose` and Command-W should close the full chat when it is key
- `windowShouldClose` must route close through `hideChatWindow()` cleanup path and return `false`, so the close action:
  - saves the current frame
  - hides pane/monitor state
  - stores an effective minimum size that fits the selected visible frame
  - sets `chatWindow` to `nil`
- The next explicit chat-open action can recreate the chat if requested; settings left-click remains no-op when the chat is absent.
- Closing full chat must not change settings panel close semantics.
- Menu-bar right-click and existing settings panel close path remain unchanged.

### Lifecycle teardown behavior

- `PetWindowController.hide()` and controller deallocation must route through a single
  `PetContentView.detachForLifecycle(preserveChatState:)` coordinator.
- `detachForLifecycle` must `orderOut`/`removeChildWindow`/`nil` all Pet-associated
  transient windows (notification, chat, whisper, summon menu, ask window).
- `detachForLifecycle` must remove local/global dismiss monitors.
- Hide/deactivate must preserve chat-frame and thread pane preference state so re-show can
  restore size behavior without duplicates.
- `hideChatWindow` should invoke `detachChatWindow(preserveState: false)` so pane-open state is cleared on explicit close.
- `PetWindowController.teardown()` is the idempotent permanent visual teardown
  path and uses the same detach coordinator; repeated calls must not re-order,
  remove, or otherwise mutate an already detached child.
- `MenuBarAppDelegate.quit()` and `applicationWillTerminate(_:)` must converge
  on one idempotent teardown that stops menu-bar timers/observers, detaches the
  Pet controller, cleans the PetModel, stops the local runtime, and closes the
  panel.
- `PetModel.cleanup()` owns cancellation of its reconnect/idle/hide/zzz/task
  resources, notification observer, shared summon owner/watchdog, and watcher
  callbacks. It is safe to call more than once.

### Ask input lifecycle

- Ask-only input installs a dedicated outside-click monitor after its child
  window is attached, with `PetContentView` as the child window delegate. A
  click outside Ask or Ask losing key status detaches the Ask child and
  releases both local/global Ask monitors.
- Ask teardown is idempotent and must not change the general chat focus policy
  or its panel dismiss monitor.

### Shared summon ownership

- Omakase, Ask, and Draft PR share one admission gate and one owner record. The
  record contains a unique token, source, phase, optional Omakase placement
  context, and the Gateway `runId` once the send ACK arrives.
- A busy owner rejects a new shared summon without replacing the source, token,
  watchdog, or run correlation. Draft PR claims the owner before starting its
  blocking worker; a late worker completion is ignored unless its token is
  still current.
- Shared sends use `sendMessageAwaitingRunId()`. Until the ACK, delta,
  message-complete, and assistant-final events are ignored. After the ACK, only
  an event whose `runId` equals the owner's `runId` may mutate or finalize it;
  `messageId` is never used as a run substitute.
- Watchdog, send-failure, disconnect, and normal completion release only the
  matching owner token. Omakase draft placement carries that same token
  through its asynchronous placement; a newer owner invalidates a late result.
- Log summons retain their separate typed dispatch and timeout behavior.

### Hidden/no-op behavior

- If chat has not been opened yet or is not visible, menu-bar left-click must:
  - not create a chat window
  - not call any reveal path that raises a non-visible chat
- When settings is already open and chat exists/visible, settings flow may bring chat forward.

### D55 / D64 regression guard expectations

- D55: notification bubble must rerun intrinsic content fit on every content refresh and
  re-clamp the existing bubble with shared contract when owned by this pet window.
- notification owner mismatch must remove stale bubble child from prior parent before replacing
- D64: content-driven resize operations (character-size and pane resize) must preserve
  the requested anchor and use the shared clamp helper to keep geometry inside screen.

### Saved-frame and close regression guard expectations

- chat open restores a valid saved frame through the shared clamp and minimum-size rules
- chat close saves the effective frame and clears the owned chat-window reference
- normal-level chat windows keep the standard close button visible

### Keyboard expectations

- Text-edit interactions in full chat continue to support standard macOS editing expectations:
  - copy (⌘C)
  - select-all (⌘A)
  - close (⌘W) through standard window controls
- These behaviors are in addition to existing chat-internal text handling and should not alter
  avatar, notification, ask, whisper, summon, A3 log logic, Gateway, restart/deploy/push workflows.

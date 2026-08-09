# Pet Floating Window Contract

## Scope

This document is the Normative contract for the Pet floating chat experience only:

- full-chat window creation and lifecycle behavior
- menu-bar left-click reveal routing for settings + chat
- z-order and activation rules
- close/reveal edge behavior and non-visible/no-op behavior

## Normative (shipped)

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
  - sets `chatWindow` to `nil`
- The next explicit chat-open action can recreate the chat if requested; settings left-click remains no-op when the chat is absent.
- Closing full chat must not change settings panel close semantics.
- Menu-bar right-click and existing settings panel close path remain unchanged.

### Hidden/no-op behavior

- If chat has not been opened yet or is not visible, menu-bar left-click must:
  - not create a chat window
  - not call any reveal path that raises a non-visible chat
- When settings is already open and chat exists/visible, settings flow may bring chat forward.

### Keyboard expectations

- Text-edit interactions in full chat continue to support standard macOS editing expectations:
  - copy (⌘C)
  - select-all (⌘A)
  - close (⌘W) through standard window controls
- These behaviors are in addition to existing chat-internal text handling and should not alter
  avatar, notification, ask, whisper, summon, A3 log logic, Gateway, restart/deploy/push workflows.

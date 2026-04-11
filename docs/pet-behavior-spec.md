# Pet Behavior Spec

## Scope

This document is the behavioral source of truth for Chi's **window tracking / movement / hide / facing** system.
It covers:

- tracked-window resolution
- side selection and movement
- facing / hide sprite selection
- hide / unhide / emerge lifecycle
- opposite-side double-click behavior
- edge handling around fullscreen, small windows, and missing host windows

It does **not** define Bridge, OpenClaw chat semantics, or Summon transport.

## Principles

1. **Chi follows the visually relevant host window, not a stale AX memory of it.**
2. **Hide mode is still attachment mode.** Hiding never means "stop tracking"; it means "track while concealed".
3. **Facing is derived from attachment side.** Side changes must update all side-dependent hide state atomically.
4. **User-forced side changes beat heuristics until that move has logically finished.**
5. **When code and this spec diverge, this spec wins.**

## Source of Truth Hierarchy

### Placement / tracking

- Primary truth for tracked window geometry: **topmost on-screen CG window for the tracked app**
- Secondary truth for context capture: **AX window element only when it matches the CG frame closely enough**
- Fallback rule: if CG says a different window is visually on top, placement follows CG even when AX focused window disagrees

### Facing / hide art

- Primary truth: **attachment side** (`left` / `right`)
- Hide suffix and hide pose offsets are derived from side; they are not independent concepts

## Trigger -> Behavior Map

### User actions

| Trigger | Intended behavior |
|---|---|
| Single click on Chi | Toggle full chat open/close |
| Double click on Chi while not hiding | Move to the opposite side of the currently tracked window |
| Double click on Chi while hiding | No opposite-side walk; hide owns placement |
| Drag Chi | Move window directly, pause auto-tracking for 30s, count as activity |
| Any activity while hiding (when `noteActivity(unhideIfNeeded: true)`) | Unhide, emerge, and resume normal idle cycle |
| Activity that only changes tracked app/window (`noteActivity(unhideIfNeeded: false)`) | Reset hide timer without forcibly unhiding |

### Window / app events

| Trigger | Intended behavior |
|---|---|
| Frontmost app changes to a non-ClawGate app while not hiding | Start following that app's active host window; arrival may wave |
| Frontmost app changes while hiding | Stay hidden and teleport to the new host edge if a valid host window exists |
| Same app, different topmost window | Follow the new topmost window |
| Host window closes but another valid host window remains | Stay attached; do **not** unhide just because focus changed |
| No valid on-screen host window remains while hiding | Unhide / stop hiding |
| No valid on-screen host window remains while not hiding | Stop movement |
| Host window becomes fullscreen | Stop movement; do not attach on fullscreen surfaces |
| Host window becomes too small (popup/dialog scale) | Stop movement; ignore tiny windows |

### Idle / hide lifecycle

| Trigger | Intended behavior |
|---|---|
| Idle for `hideAfterMinutes` and selected character is `chi-claw` | Enter hiding |
| Enter hiding | Lock expression, stop locomotion, switch to `.hideClaw`, start micro-loop |
| While hiding, periodic peek timer fires | Briefly show one of the peek poses, then return to `.hideClaw` |
| While hiding, zzz check fires | Whisper `zzz…` only when still in `.hideClaw`, on cooldown, and random roll succeeds |
| Unhide | Teleport to normal idle position, play emerge briefly, then clear suffix, return to idle, resume cycle |

### Connection / non-placement events that still affect visible behavior

| Trigger | Intended behavior |
|---|---|
| Disconnect while visible | Expression may change to sleep / whisper `link lost`, but hiding logic must not emit `zzz…` for disconnect |
| Disconnect while hiding | Remain hidden; `zzz…` only follows hide rules, not connection loss |

## State Variables and Invariants

### Placement variables

- `lastPlacementSide`
  - Last resolved visible attachment side in normal mode
  - Also the side chosen when entering hiding
- `lockedPlacementSide`
  - Temporary user-forced side lock for opposite-side moves
  - Exists to prevent the distance heuristic from snapping Chi back to the origin side mid-transition
- `lockedPlacementWindowFrame`
  - Frame identity paired with `lockedPlacementSide`
  - Lock is only valid while the tracked host window is still effectively the same window
- `lastTrackedWindow`
  - AX element for context capture only when AX and CG agree closely enough
- `lastTrackedWindowFrame`
  - Last resolved tracked window frame used for context and placement continuity

### Hide / facing variables

- `isHiding`
  - Master switch for concealed behavior
- `hidingSide`
  - Side Chi is currently hiding on
- `stateMachine.hideAnimationSuffix`
  - Sprite suffix for side-specific hide art
- `stateMachine.expression`
  - Current visible hide pose (`hideClaw`, `hidePeek*`, `hideEmerge`) or normal expression

### Required atomicity

The following fields form one side/facing bundle and must be updated together whenever hidden side changes:

- `hidingSide`
- `lastPlacementSide`
- `stateMachine.hideAnimationSuffix`
- any currently active hide expression that depends on side-specific art

**Invariant:** it must be impossible for `hidingSide` to say "left" while `hideAnimationSuffix` still points at right-side art.

### Lock invariants

- `lockedPlacementSide` is set only for deliberate user-forced opposite-side movement
- The lock remains active until one of these happens:
  - arrival / movement logically completes
  - tracked window changes materially
  - tracking is stopped / invalidated
- Regular distance heuristics must not override a valid lock for the same host window

## Facing and Sprite Selection Rules

### Normal mode

- Facing in normal visible placement is expressed by movement animation and idle placement side
- Side choice in normal mode is a placement decision, not a suffix decision

### Hide mode

- Hide sprites are side-specific through `hideAnimationSuffix`
- Mapping:
  - right-side attachment -> no suffix (`""`)
  - left-side attachment -> `"-left"`
- `resolvedAnimationName` must combine hide expressions with the current suffix only while locomotion is stationary

### Pose offsets

`PetRenderMetrics` owns the render-derived geometry needed to make hide art line up with the host edge:

- `overlap`
- `clawFix`
- `hiddenPoseOffsetX(...)`
- rendered width / inset derived from actual window-fit scale

Intent:

- hide claw pose sits flush on the host edge
- peek variants preserve perceived claw alignment when switching from claw-only to face-visible poses
- size changes scale from render metrics, not hardcoded 128-sized assumptions

## Window Tracking Contract

### `resolveTrackedWindow` contract

The tracked window resolver should return:

- CG topmost frame as the placement truth
- AX element only when AX frame and CG frame roughly match

Implications:

- placement follows actual Z-order
- context capture may use AX when trustworthy
- when AX is stale or disagrees, Chi still follows the visually topmost window without fabricating a stale AX identity

### `lastTrackedWindow` / context capture

`lastTrackedWindow` exists for context capture, not as a stronger truth than CG.
If AX cannot be matched to the current CG topmost frame, context capture must treat AX identity as unavailable rather than pretending the stale focused window is current.

## Opposite-Side Double-Click Contract

### Intended behavior

Double-clicking Chi while visible means:

1. choose the side opposite `lastPlacementSide`
2. force placement to that side for the currently tracked host window
3. keep that choice stable until the move has logically resolved or the host window changes

### Why the lock exists

Without a sticky lock, the regular distance heuristic will often prefer the old side while Chi is still near the departure edge, causing oscillation.

### Unlock conditions

A sticky opposite-side choice may be cleared when:

- the move has finished and normal side heuristics may resume
- the tracked window changed enough to count as a different host
- tracking became invalid (no host window, fullscreen skip, stop)

## Hide / Unhide Lifecycle

### Enter hiding

1. verify `chi-claw` and hide enabled conditions
2. set `isHiding = true`
3. capture current visible side as hidden side
4. stop movement
5. lock expression changes from unrelated events
6. enter `.hideClaw`
7. start micro-loop and zzz scheduling

### While hiding

- Tracking continues
- Repositioning is immediate, not walking animation
- Host changes do **not** automatically unhide if a valid new host exists
- Peek poses are temporary overlays on the same hidden-side attachment

### Hidden app/window switch

When the current hidden side is no longer feasible on the new host window:

1. If the opposite side is feasible, flip hidden side **atomically** and immediately reposition
2. If neither side is feasible, unhide and stop concealing

This preserves both attachment and facing correctness.

### Unhide

1. clear hiding state and timers
2. keep hide suffix long enough for emerge art to face the correct direction
3. teleport to the visible idle position for the current host
4. play `.hideEmerge`
5. after emerge finishes, clear suffix and return to `.idle`
6. resume normal idle cycle

## Edge Cases and Intended Outcomes

### Fullscreen host

- Chi should not cling to fullscreen windows
- Movement is stopped instead of forcing awkward edge attachment

### Tiny windows / dialogs

- Chi ignores small transient windows
- This prevents attachment to popups/tooltips/dialog scraps

### No valid candidate side

- Visible mode: use fallback placement inside the visible screen bounds
- Hidden mode: if no side can hide behind, unhide rather than floating in a broken concealed state

### Topmost/focused disagreement

- CG topmost wins for placement
- AX focused is advisory for context only

### Zzz whisper

- Only legal while hiding, in `.hideClaw`, with no face showing
- Never reused as a generic disconnect cue

## Whisper Positioning

- `zzz…` is a **claw whisper**, not a head whisper.
- While Chi is hidden in `.hideClaw`, the whisper bubble must stay **outside the active host window body**.
- The claw-side anchor is based on the **measured hide-claw sprite bounds**, not the pet window edge or window center.
- Side rule for `zzz…`:
  - hidden on the right side of the host -> align the bubble's **left edge** to the claw's outer-right edge and let the bubble rise on the screen-right side
  - hidden on the left side of the host -> align the bubble's **right edge** to the claw's outer-left edge and let the bubble rise on the screen-left side
- If the screen edge prevents a pure side placement, the bubble should be lifted upward before it is allowed to intrude over the host window body.
- All other whispers (`Connected`, `link lost`, normal reactions, and any whisper shown during visible peek/emerge states) anchor above Chi's head area.
- The whisper bubble's bottom edge should align to the semantic anchor area:
  - claw whisper -> claw area
  - all other whispers -> head area

## Working Tree Recommendation

Current uncommitted `PetModel.swift` changes should **not** be treated as authoritative yet.

Recommended handling:

1. keep this spec as the behavioral source of truth
2. **revert the current dirty `PetModel.swift` patch back to the last committed state before further runtime edits**
3. reapply fixes from this spec intentionally, in small committed steps

Reason:

- the current dirty patch is a half-integrated stabilization attempt
- user-observed instability means it is not yet trustworthy as behavior truth
- spec-first reconstruction is safer than patching on top of an already unstable working tree

## Resolved Decisions

1. `lockedPlacementSide` is cleared on the next stable tracking tick after locomotion has stopped, or immediately when the tracked host materially changes.
2. When AX cannot be matched to the current CG topmost frame, context capture operates without AX window identity rather than inventing a stale match.
3. Hidden side flips normalize any active peek pose back to `.hideClaw` before the new side is shown.
4. Placement clamps against the host display's visible frame, not `NSScreen.main`.
5. Fullscreen transitions clear placement lock immediately because edge attachment is no longer valid.

# ClawGate Chrome extension

Source: `extensions/clawgate-chrome/`. Manifest V3, currently `0.8.0`.

The extension is the browser half of ClawGate. It sends pages you choose to Chi,
records where you have been, and — on Messenger only — reads the conversation on
screen so Chi can reason about business correspondence.

Everything below is taken from the source. Where behaviour is governed by an
OpenClaw contract, this page points at the contract rather than restating it;
`docs/contracts/messenger-capture.md` in the `oc-general` repository is
normative for the Messenger ingest seam.

## Install and reload

The extension is loaded unpacked; it is not published to the Web Store.

1. Open `chrome://extensions/` and turn on Developer mode.
2. Choose "Load unpacked" and select `extensions/clawgate-chrome/`.
3. Confirm the version shown matches `manifest.json`.

The app can start this for you: the ClawGate Settings pane reveals the folder in
Finder and opens `chrome://extensions/` (`ClawGate/UI/SettingsView.swift`). It
prefers the copy bundled in `ClawGate.app/Contents/Resources/clawgate-chrome`
and falls back to the source directory for dev builds.

After changing extension source, press Reload on the extension card. The version
in `manifest.json` is bumped whenever behaviour changes, so the number on the
card is how you tell which build is running.

`scripts/restart-local-clawgate.sh` syncs the source directory into the app
bundle, so the bundled copy and the repository stay in step; it does not reload
the copy Chrome already holds.

## Connecting to the gateway

The extension needs a gateway URL and token before it sends anything. Both are
read from the ClawGate app's local bridge at
`http://127.0.0.1:{bridgePort}/v1/openclaw-info`, which returns the gateway
host, port and token. Nothing is typed by hand and no credential is stored in
this repository.

- **Automatic.** `ensureGatewayConfigured()` runs on every poll tick (2.5 s) and
  fetches the bootstrap payload whenever the settings are empty. A freshly
  loaded extension configures itself within a few seconds of the app running.
- **Manual.** The popup's *Connect to ClawGate* button performs the same fetch
  on demand. The button reads *Reconnect* once settings exist.
- **Check.** *Test Connection* calls `/health` on the configured gateway.

The toolbar badge shows `!` while the extension is unconfigured.

The popup also carries the passive-tracking toggle and a link to the options
page, which manages the domain exclusion list. Excluded domains, `localhost`,
`127.0.0.1` and the gateway's own host are never captured
(`isPassiveEligibleURL`).

## What it captures

### On demand

Right-click a page and choose the ClawGate context-menu item to send that page
to Chi. Text is extracted from the main content region, capped at 5000
characters. One image may be OCR'd in a sandboxed frame (`sandbox/ocr.html`),
capped at 800 characters.

Extracted text passes through `stripInjectionPatterns()`, which replaces prompt
injection markers with `[FILTERED]`, and `detectInjectionAttempt()` flags a page
whose content tries to address the model. Page content is untrusted input.

### Passive browsing history

While passive tracking is on, a visit is recorded after the tab has been active
for 8 seconds. Entries are queued (max 50) and flushed on a 1.5-minute alarm to
`/api/web-history`. The same URL is not re-sent within 30 minutes. The last 200
sends are kept in `chrome.storage.local` under `passiveSendLog` for debugging.

### Messenger conversations

Messenger is handled on its own path. `isMessengerPage()` matches
`messenger.com` and `facebook.com/messages`, and those tabs go to
`/api/messenger-capture` instead of the web-history route.

**Cadence.** The dwell wait is skipped entirely for Messenger, and a
`MutationObserver` on the message log notifies the service worker 2 s after the
DOM settles. The 1.5-minute alarm remains as a backstop. Captures are deduped by
a content signature rather than by a time window, so re-viewing an unchanged
thread costs nothing.

**Scope.** The extension reads rendered DOM, so it observes a window and never a
thread: `captureScope` is always `visible_window`, bounded at the 30 most recent
messages. The sidebar is virtualised and carries its own `visible_window` scope
for the same reason. No consumer may conclude a message is unanswered — only
that no reply appears inside the captured window.

**Per message:** sender, whether it is yours, text (500 chars), timestamp and its
precision, a deterministic id, reactions, read receipts, the name replied to,
and attachments.

**Per thread:** thread id, contact name, participants, message count, oldest
captured timestamp, content signature.

**Per capture:** the sidebar rows (thread id, name, group flag, unread flag,
preview text, relative age as rendered) and unread counts per folder.

## Reading the DOM at the strength it states things

Messenger's accessibility labels state some things exactly, some approximately,
and some not at all. The extractor is built to preserve that difference rather
than flatten it.

**Timestamps** come in three shapes, and all three are parsed:

| Rendered | Meaning | `sentAtPrecision` |
|---|---|---|
| `2024年3月11日 19:32` | older than about a week | `exact` |
| `2026年8月14日(金) 11:02` | within about a week | `exact` |
| `18:51` | today; no date is rendered | `inferred_date` |

A bare time is resolved against the capture date, because Messenger relabels a
message with a date the moment it stops being today. That reconstruction is
reported as `inferred_date`, never as `exact`: the date was rebuilt, not read. A
resolved time in the future is rolled back a day rather than claiming a message
that has not happened. An unparsable label falls back to the capture time and is
marked `approximate`, which downstream treats as no timestamp at all.

**Rows Messenger stamps with the Unix epoch** are its end-to-end-encryption
notice, not messages, and are dropped rather than stored with a 1970 date. The
filter is on the year, not the sender, so legitimate events such as a group
rename survive.

**Reactions** report a count and up to two emoji. They never report who reacted:
the label ends before naming anyone. The "react with an emoji" affordance sits on
every message and is not a reaction.

**Read receipts** name a reader and carry a timestamp in the same three shapes as
message text. A reader whose timestamp does not parse is still recorded, with a
null time — who read it is worth keeping even when when it is not.

**Sidebar ages** (`約1時間前`, `1日前`) are stored as the strings Messenger
rendered. The sidebar carries no absolute time anywhere, so converting one would
manufacture a precision the DOM never had.

**Attachment labels** concatenate title and domain with no delimiter
(`"...| Noteswww.example.com"`), so the label is passed through whole rather
than split on a guess.

## Identity guards

Two failures are structural rather than cosmetic, and both are guarded.

**The screen and the URL can disagree.** Messenger is a single-page app: clicking
a conversation changes the URL immediately while the log keeps rendering the
previous thread. Reading the id from the URL and the messages from the DOM in
that window files one conversation under another contact. The sidebar marks the
conversation actually on screen with `aria-current="page"`; when that disagrees
with the URL the capture is refused, and the observer fires again once the log
catches up.

**A thread id may not exist yet.** A capture landing before the URL resolves to a
thread is skipped rather than keyed off a hash of the URL, which would invent a
thread that then sits beside the real one.

The thread heading is a screen-reader landmark carrying a decorated title, so the
undecorated name is preferred and the decoration stripped as a fallback.

## Known limits

- **Minute resolution.** Messenger timestamps resolve to the minute, so the same
  sender, minute and text collapse to one message id. Mixing window position into
  the key would separate them but would not survive scrolling.
- **Sender labels are not identities.** The same person appears as a given name in
  one thread and a full name in another, sometimes within one capture. Do not key
  person resolution on `sender`.
- **Participants is who the composer names.** For a large group that is the group
  name, not a member list.
- **Viewer timezone.** Times resolve in the browser's timezone, which need not be
  the account's. Both the label and the captured instant shift together, so the
  skew is not detectable downstream.
- **Encrypted history.** Only messages already decrypted and rendered are
  readable. Restoring older history requires a PIN, and the extension does not
  and will not automate that.
- **Only the tab you are looking at.** Passive capture starts from
  `chrome.tabs.onActivated` / `onUpdated` and ignores tabs that are not active, so
  a Messenger tab sitting in the background is not captured.

## Tests

```
cd extensions/clawgate-chrome && node --test tests/*.test.js
```

`tests/messenger-timestamp.test.js` covers the three timestamp shapes, the
`inferred_date` reconstruction and its convergence with the dated label, the
future rollback, the epoch-notice rejection, contact-name selection, the
reaction affordance not counting as a reaction, and a read receipt keeping its
reader when its time does not parse. `tests/ocr-sandbox-postmessage.test.js`
covers the OCR sandbox's origin handling.

Examples in tests use invented names. Real conversation content never belongs in
this repository — see the privacy boundary in `AGENTS.md`.

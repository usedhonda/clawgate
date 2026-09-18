// Google Meet call detector and speaking-tile reader.
//
// While a call is up it reports to the background every 10s; ClawGate records
// Chrome's output (the remote party) only while these heartbeats keep arriving,
// and treats 30s of silence as the call ending.
//
// It also watches which participant tile shows Meet's speaking indicator and
// reports each start/stop edge at once, so ClawGate can put a name on the remote
// party's lines. Tile structure and speaking classes follow Vexa's gmeet
// speaker detection (github.com/Vexa-ai/vexa, Apache-2.0,
// core/meetings/modules/gmeet-capture/src/gmeet-speakers.ts). The classes are
// obfuscated and may change; unknown means "not speaking", so a changed class
// leaves lines unnamed rather than wrongly named.
(() => {
  const HEARTBEAT_MS = 10_000;
  const SCAN_MS = 250;
  const STOP_GRACE_MS = 750;

  // The leave-call button exists only inside a call (not in the lobby or after
  // hanging up). Labels are matched in Japanese and English UI.
  const LEAVE_SELECTOR = [
    'button[aria-label*="通話から退出"]',
    'button[aria-label*="Leave call"]',
  ].join(', ');
  const TILE_SELECTOR = '[data-participant-id]';
  const SPEAKING_CLASSES = ['Oaajhc', 'HX2H7', 'wEsLMd', 'OgVli'];
  const JUNK_NAME = /^Google Participant \(|spaces\/|devices\//;

  function inCall() {
    return document.querySelector(LEAVE_SELECTOR) !== null;
  }

  function send(payload) {
    try {
      chrome.runtime.sendMessage({ type: 'meet_call_state', ...payload });
    } catch {
      // Extension reloaded under this page; the next page load re-injects us.
    }
  }

  // --- speaking tiles ---------------------------------------------------------

  function isSelf(tile) {
    return tile.hasAttribute('data-self-name') || tile.querySelector('[data-self-name]') !== null;
  }

  function tileName(tile) {
    const text = tile.querySelector('span.notranslate')?.textContent?.trim() || '';
    return text && !JUNK_NAME.test(text) ? text : null;
  }

  function tileSpeaking(tile) {
    return SPEAKING_CLASSES.some((cls) =>
      tile.classList.contains(cls) || tile.querySelector(`.${cls}`) !== null);
  }

  const speaking = new Map();   // name -> last time seen lit (ms)
  let knownClassHits = 0;
  let lastSignal = { tiles: 0, named: 0 };

  function scanTiles() {
    const now = Date.now();
    const lit = new Set();
    let tiles = 0;
    let named = 0;
    const seen = new Set();
    document.querySelectorAll(TILE_SELECTOR).forEach((tile) => {
      const id = tile.getAttribute('data-participant-id');
      if (!id || seen.has(id)) return;   // a participant renders nested tiles
      seen.add(id);
      if (isSelf(tile)) return;
      tiles += 1;
      const name = tileName(tile);
      if (!name) return;
      named += 1;
      if (tileSpeaking(tile)) {
        knownClassHits += 1;
        lit.add(name);
      }
    });
    lastSignal = { tiles, named };

    for (const name of lit) {
      if (!speaking.has(name)) {
        send({ inCall: true, speakerEdge: { name, speaking: true, at: now } });
      }
      speaking.set(name, now);
    }
    for (const [name, lastLit] of speaking) {
      if (!lit.has(name) && now - lastLit >= STOP_GRACE_MS) {
        speaking.delete(name);
        send({ inCall: true, speakerEdge: { name, speaking: false, at: lastLit } });
      }
    }
  }

  function endAllSpeaking() {
    for (const [name, lastLit] of speaking) {
      send({ inCall: true, speakerEdge: { name, speaking: false, at: lastLit } });
    }
    speaking.clear();
  }

  // --- heartbeat --------------------------------------------------------------

  let lastReported = null;

  function report() {
    const current = inCall();
    // Report every tick while in a call (heartbeat); report "ended" once.
    if (!current && lastReported === false) return;
    lastReported = current;
    if (current) {
      send({ inCall: true, signal: { ...lastSignal, knownClassHits } });
      knownClassHits = 0;
    } else {
      endAllSpeaking();
      send({ inCall: false });
    }
  }

  report();
  setInterval(report, HEARTBEAT_MS);
  setInterval(() => { if (inCall()) scanTiles(); }, SCAN_MS);
  window.addEventListener('pagehide', () => {
    if (lastReported) {
      endAllSpeaking();
      send({ inCall: false });
    }
  });
})();

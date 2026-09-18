// Google Meet call detector. While a call is up, report it to the background
// every 10s; ClawGate records Chrome's output (the remote party) only while
// these heartbeats keep arriving, and treats 30s of silence as the call ending.
(() => {
  const HEARTBEAT_MS = 10_000;

  // The leave-call button exists only inside a call (not in the lobby or after
  // hanging up). Labels are matched in Japanese and English UI.
  const LEAVE_SELECTOR = [
    'button[aria-label*="通話から退出"]',
    'button[aria-label*="Leave call"]',
  ].join(', ');

  function inCall() {
    return document.querySelector(LEAVE_SELECTOR) !== null;
  }

  let lastReported = null;

  function report() {
    const current = inCall();
    // Report every tick while in a call (heartbeat); report "ended" once.
    if (!current && lastReported === false) return;
    lastReported = current;
    try {
      chrome.runtime.sendMessage({ type: 'meet_call_state', inCall: current });
    } catch {
      // Extension reloaded under this page; the next page load re-injects us.
    }
  }

  report();
  setInterval(report, HEARTBEAT_MS);
  window.addEventListener('pagehide', () => {
    if (lastReported) {
      try { chrome.runtime.sendMessage({ type: 'meet_call_state', inCall: false }); } catch { /* ignore */ }
    }
  });
})();

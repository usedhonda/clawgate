const REQUEST_TIMEOUT_MS = 10_000;

function cancelResponseBody(response) {
  // Cancellation is cleanup, never another thing the caller must wait for.
  try { response?.body?.cancel()?.catch(() => undefined); } catch {}
}

// Keep the deadline alive through the caller's body read. Aborting fetch alone
// is insufficient if a transport/mock does not settle promptly on cancellation.
// Do not follow redirects with captured personal data or Gateway credentials.
export async function fetchWithDeadline(url, options = {}, consume = (response) => response) {
  const controller = new AbortController();
  let response;
  let timer;
  const timeoutError = new Error('Request timed out');
  timeoutError.name = 'TimeoutError';
  try {
    return await Promise.race([
      Promise.resolve().then(async () => {
        response = await fetch(url, { ...options, redirect: 'error', signal: controller.signal });
        if (controller.signal.aborted) {
          cancelResponseBody(response);
          throw timeoutError;
        }
        return consume(response);
      }),
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          reject(timeoutError);
          controller.abort();
        }, REQUEST_TIMEOUT_MS);
      }),
    ]);
  } finally {
    clearTimeout(timer);
    cancelResponseBody(response);
  }
}

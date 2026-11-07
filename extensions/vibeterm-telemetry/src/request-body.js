// Bounds apply to bytes actually received, including chunked requests. The
// deadline covers the complete body, not just arrival of the headers.
export const MAX_BODY_BYTES = 1024 * 1024;
const BODY_TIMEOUT_MS = 10_000;

export class RequestBodyError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    let settled = false;
    let timer;

    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      req.off("data", onData);
      req.off("end", onEnd);
      req.off("error", onError);
      req.off("aborted", onAborted);
      req.off("close", onClose);
      if (error) {
        // Leave unread bytes on the socket. The handler closes it after the
        // error response, so a rejected upload is neither buffered nor drained.
        req.pause();
        // IncomingMessage can emit an error after an aborted/closed upload.
        // Keep one listener until the stream closes rather than leaving an
        // unhandled EventEmitter error during rejection cleanup.
        req.once("error", onError);
        req.once("close", () => req.off("error", onError));
        chunks.length = 0;
        reject(error);
      } else {
        resolve(Buffer.concat(chunks, bytes).toString("utf-8"));
      }
    };
    const onData = (chunk) => {
      const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += data.length;
      if (bytes > MAX_BODY_BYTES) {
        finish(new RequestBodyError(413, "PAYLOAD_TOO_LARGE", "Telemetry body exceeds 1 MiB"));
        return;
      }
      chunks.push(data);
    };
    const onEnd = () => finish();
    const onError = () => finish(new RequestBodyError(400, "BAD_REQUEST", "Failed to read request body"));
    const onAborted = () => finish(new RequestBodyError(400, "BAD_REQUEST", "Request was aborted"));
    const onClose = () => { if (!req.complete) onAborted(); };

    const contentLength = req.headers["content-length"];
    if (contentLength !== undefined &&
        (typeof contentLength !== "string" || !/^\d+$/.test(contentLength))) {
      finish(new RequestBodyError(400, "BAD_REQUEST", "Invalid Content-Length"));
      return;
    }
    if (Number(contentLength) > MAX_BODY_BYTES) {
      finish(new RequestBodyError(413, "PAYLOAD_TOO_LARGE", "Telemetry body exceeds 1 MiB"));
      return;
    }

    req.on("data", onData);
    req.once("end", onEnd);
    req.once("error", onError);
    req.once("aborted", onAborted);
    req.once("close", onClose);
    timer = setTimeout(() => {
      finish(new RequestBodyError(408, "REQUEST_TIMEOUT", "Telemetry body read timed out"));
    }, BODY_TIMEOUT_MS);
    timer.unref?.();
  });
}

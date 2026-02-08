/**
 * Bearer token authentication for telemetry endpoint.
 * Validates against the OpenClaw gateway auth token.
 */

/**
 * Extract Bearer token from Authorization header.
 * @param {string | undefined} header
 * @returns {string | null}
 */
function extractBearerToken(header) {
  if (!header) return null;
  const match = header.match(/^Bearer\s+(\S+)$/i);
  return match ? match[1] : null;
}

/**
 * Verify the request's Bearer token against the gateway token.
 * @param {import("http").IncomingMessage} req
 * @param {string} gatewayToken
 * @returns {{ valid: boolean, error?: string }}
 */
export function verifyAuth(req, gatewayToken) {
  const token = extractBearerToken(req.headers.authorization);
  if (!token) {
    return { valid: false, error: "Missing or malformed Authorization header" };
  }
  if (token !== gatewayToken) {
    return { valid: false, error: "Invalid token" };
  }
  return { valid: true };
}

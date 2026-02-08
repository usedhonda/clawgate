/**
 * Vibeterm Telemetry plugin for OpenClaw.
 *
 * Registers POST /api/telemetry — receives batched location samples
 * from the Vibeterm iOS app (Background URLSession).
 */

import { createTelemetryHandler } from "./src/handler.js";

const plugin = {
  id: "vibeterm-telemetry",
  name: "Vibeterm Telemetry",
  description: "REST endpoint for Vibeterm iOS location telemetry",

  configSchema: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },

  register(api) {
    const handler = createTelemetryHandler(api);
    api.registerHttpRoute({
      path: "/api/telemetry",
      handler,
    });
    api.logger?.info?.("vibeterm-telemetry: registered POST /api/telemetry");
  },
};

export default plugin;

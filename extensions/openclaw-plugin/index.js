/**
 * OpenClaw plugin entry point for ClawGate.
 *
 * Registers the ClawGate channel plugin, which bridges LINE messaging
 * via the ClawGate AX automation server on localhost:8765.
 */

import { clawgatePlugin } from "./src/channel.js";
import { setGatewayRuntime } from "./src/gateway.js";
import { createTprojMailboxService, setTprojMailboxRuntime } from "./src/tproj-mailbox.js";

const plugin = {
  id: "clawgate",
  name: "ClawGate",
  description: "LINE messaging via ClawGate AX bridge",

  configSchema: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },

  register(api) {
    setGatewayRuntime(api.runtime);
    setTprojMailboxRuntime(api.runtime);
    api.registerChannel({ plugin: clawgatePlugin });
    if (typeof api.registerService === "function") {
      api.registerService(createTprojMailboxService({ runtime: api.runtime }));
    }
  },
};

export default plugin;

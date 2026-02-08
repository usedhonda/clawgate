/**
 * ClawGate ChannelPlugin definition — ties config, outbound, and gateway together.
 */

import { listAccountIds, resolveAccount, defaultAccountId } from "./config.js";
import { outbound } from "./outbound.js";
import { startAccount } from "./gateway.js";

export const clawgatePlugin = {
  id: "clawgate",

  meta: {
    id: "clawgate",
    label: "ClawGate",
    selectionLabel: "ClawGate (LINE)",
    blurb: "LINE messaging via ClawGate AX bridge.",
  },

  capabilities: {
    chatTypes: ["direct"],
    media: false,
    nativeCommands: false,
    polls: false,
    reactions: false,
    threads: false,
  },

  config: {
    listAccountIds: (cfg) => listAccountIds(cfg),
    resolveAccount: (cfg, accountId) => resolveAccount(cfg, accountId),
    defaultAccountId: (cfg) => defaultAccountId(cfg),

    setAccountEnabled: ({ cfg, accountId, enabled }) => {
      const next = structuredClone(cfg);
      if (!next.channels) next.channels = {};
      if (!next.channels.clawgate) next.channels.clawgate = {};
      if (!next.channels.clawgate[accountId]) next.channels.clawgate[accountId] = {};
      next.channels.clawgate[accountId].enabled = enabled;
      return next;
    },

    deleteAccount: ({ cfg, accountId }) => {
      const next = structuredClone(cfg);
      if (next.channels?.clawgate?.[accountId]) {
        delete next.channels.clawgate[accountId];
      }
      return next;
    },

    isConfigured: (account) => Boolean(account.apiUrl),

    describeAccount: (account) => ({
      accountId: account.accountId,
      apiUrl: account.apiUrl,
      defaultConversation: account.defaultConversation,
    }),
  },

  security: {
    resolveDmPolicy: ({ account }) => ({
      policy: "open",
      allowFrom: [],
    }),
  },

  outbound,

  gateway: {
    startAccount: async (ctx) => {
      return startAccount(ctx);
    },
  },

  status: {
    defaultRuntime: {
      accountId: "default",
      running: false,
      lastStartAt: null,
      lastStopAt: null,
      lastError: null,
    },

    buildChannelSummary: ({ snapshot }) => ({
      accounts: snapshot?.accounts?.length ?? 0,
    }),

    buildAccountSnapshot: ({ account, runtime }) => ({
      accountId: account.accountId,
      enabled: account.enabled,
      running: runtime?.running ?? false,
      apiUrl: account.apiUrl,
    }),
  },
};

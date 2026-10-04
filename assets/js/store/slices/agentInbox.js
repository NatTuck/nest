/**
 * Async agent-to-agent inbox (`agents-send`) cache setters.
 *
 * The full queued-message list rides the `chat:inbox` event and the
 * `init` payload; `chat:status` carries only the count. Split into its
 * own slice so `agentCache.js` stays under the file-size cap.
 */

export function agentInboxSetters(set) {
  return {
    setAgentInbox: (id, messages) => {
      const list = Array.isArray(messages) ? messages : [];
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, inbox: list, pendingMessageCount: list.length },
          },
        };
      });
    },
  };
}

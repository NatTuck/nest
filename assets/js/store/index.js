/**
 * Zustand store for global application state.
 *
 * The store now contains ONLY immutable data. Mutable channel refs are in
 * channels.js. Channel callbacks call these store methods.
 *
 * The store is composed from slice modules (catalog, agent-cache, auth)
 * plus the shared helpers, so this file stays under the source-line cap.
 */

import { create } from "zustand";
import { devtools } from "zustand/middleware";
import { initialState } from "./helpers";
import { catalogSetters } from "./slices/catalog";
import { authSetters } from "./slices/auth";
import { agentCacheSetters } from "./slices/agentCache";
import { agentCacheStreamingSetters } from "./slices/agentCacheStreaming";
import { addChatDelta } from "./slices/agentCacheDeltas";
import { addChatMessage, addUserMessage } from "./slices/agentCacheMessages";

export const useStore = create(
  devtools(
    (set, get) => ({
      ...initialState,
      brokenAgents: [],
      ...catalogSetters(set),
      ...authSetters(set),
      ...agentCacheSetters(set),
      ...agentCacheStreamingSetters(set, get),
      addChatDelta: (id, payload) => addChatDelta(set, get, id, payload),
      addChatMessage: (id, message) => addChatMessage(set, get, id, message),
      addUserMessage: (id, content, mode) =>
        addUserMessage(set, id, content, mode),
    }),
    { name: "nest-store" },
  ),
);

/**
 * Get initial state (for testing)
 */
export { initialState };

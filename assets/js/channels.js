/**
 * Channel Management Module
 *
 * Aggregates the channel lifecycle + pushes, split across:
 *   - `./channels/state`  — shared channel refs + helpers
 *   - `./channels/agent`  — agent-channel join + chat actions
 *   - `./channels/lobby`  — lobby join + space/model/invite pushes
 *
 * `initChannels` lives here (it owns the socket lifecycle hookup).
 */

import { readAuthToken } from "./socket";
import { getStore, socket } from "./channels/state";

export * from "./channels/state";
export * from "./channels/agent";
export * from "./channels/lobby";

/**
 * Initialize channels module.
 *
 * Hooks the socket lifecycle callbacks AND opens the
 * connection — but only when a token is present in
 * `localStorage`. Called from `Layout`'s `useEffect`.
 */
export function initChannels() {
  const store = getStore();
  socket.onOpen(() => store.setIsConnected(true));
  socket.onClose(() => store.setIsConnected(false));
  socket.onError(() => store.setIsConnected(false));

  if (readAuthToken() && !socket.isConnected()) {
    socket.connect();
  }
}

/**
 * Channel Management Module
 *
 * Aggregates the channel lifecycle + pushes, split across:
 *   - `./channels/state`  — shared channel refs + helpers
 *   - `./channels/agent`  — agent-channel join + chat actions
 *   - `./channels/shellJobs` — background shell-job kill / list / log
 *   - `./channels/lobby`  — lobby join + space/model/invite pushes
 *   - `./channels/spaceNotes` — the space feed's read and its composer's send
 *
 * `initChannels` lives here (it owns the socket lifecycle hookup).
 */

import { readAuthToken } from "./socket";
import { getStore, socket } from "./channels/state";

export * from "./channels/state";
export * from "./channels/agent";
export * from "./channels/shellJobs";
export * from "./channels/lobby";
export * from "./channels/spaceNotes";

// Refs for the socket lifecycle registrations, so a repeated `initChannels()`
// REPLACES them rather than adding another set. Phoenix's client does not
// dedupe: each `onOpen`/`onClose`/`onError` pushes another `[ref, callback]`
// pair into its own list and `off/1` is the only removal, so without this the
// two mount effects that call `initChannels` (`RootGate` and `Layout`) leave
// two handlers on every event — and React StrictMode's double-invoked mount
// effect makes that four in development.
let socketCallbackRefs = [];

/**
 * Initialize channels module.
 *
 * Hooks the socket lifecycle callbacks AND opens the
 * connection — but only when a token is present in
 * `localStorage`. Called from `RootGate` and `Layout`.
 *
 * Idempotent: a second call replaces this module's own lifecycle
 * registrations instead of stacking a second set (see
 * `socketCallbackRefs` above).
 *
 * Also records *whether the connection has failed*, not just whether it is
 * up. `isConnected` alone cannot express that — it is `false` both before the
 * handshake lands and after it fails — and the gate at `/` has to tell those
 * apart to stop showing a spinner forever (issue #95). Note the client cannot
 * distinguish a rejected token from an unreachable server: the browser's
 * WebSocket API does not expose the handshake's HTTP status, so Phoenix hands
 * us a bare error event and a `1006` close for both. `connectionFailed` means
 * "we dialled and did not get a connection", and is deliberately not called
 * anything stronger.
 */
export function initChannels() {
  const store = getStore();

  if (socketCallbackRefs.length > 0) socket.off(socketCallbackRefs);

  socketCallbackRefs = [
    socket.onOpen(() => {
      store.setIsConnected(true);
      store.setConnectionFailed(false);
    }),
    socket.onClose(() => {
      store.setIsConnected(false);
      store.setConnectionFailed(true);
    }),
    socket.onError(() => {
      store.setIsConnected(false);
      store.setConnectionFailed(true);
    }),
  ];

  if (readAuthToken() && !socket.isConnected()) {
    socket.connect();
  }
}

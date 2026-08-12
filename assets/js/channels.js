/**
 * Channel Management Module
 *
 * Manages Phoenix channel lifecycle separately from state.
 * Holds channel refs as module-level variables.
 */

import { socket, readAuthToken } from "./socket";
import { useStore } from "./store";

// Module-level channel refs (NOT in store - they're mutable references)
let lobbyChannel = null;
export const agentChannels = new Map(); // agentId -> Channel
const joinFailedAgents = new Set(); // Track agents that failed to join

/**
 * Get the socket instance
 * @returns {Object} The socket instance
 */
export function getSocket() {
  return socket;
}

/**
 * Clear all agent channels (for testing)
 */
export function clearAgentChannels() {
  agentChannels.clear();
}
function getStore() {
  return useStore.getState();
}

/**
 * Initialize channels module.
 *
 * Hooks the socket lifecycle callbacks AND opens the
 * connection — but only when a token is present in
 * `localStorage`. This is called from `Layout`'s
 * `useEffect`, which only runs on authenticated routes
 * (`/`, `/agent/:name`, `/about`, `/invites`). On
 * `/login` and `/register` (sibling top-level routes
 * outside `Layout`), `initChannels` is never called and
 * the socket stays closed, so the server doesn't see
 * anonymous `/socket` dial-ins and spam its log.
 *
 * If a token appears later (login/register success
 * navigates into `Layout`), `initChannels` runs again and
 * opens the connection. If the token disappears (logout),
 * `handleLogout` in `Sidebar.jsx` calls `disconnect()`
 * directly via `window.__nest_socket`.
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

/**
 * Join lobby channel
 */
export function joinLobby(onOk, onError) {
  if (lobbyChannel) {
    if (onOk) onOk();
    return;
  }

  lobbyChannel = socket.channel("lobby");

  lobbyChannel.on("init", (payload) => {
    const store = getStore();
    store.setAgents(payload.agents || []);
    store.setBrokenAgents(payload.broken_agents || []);
    store.setModels(payload.models || []);
    store.setVocations(payload.vocations || []);
    store.setSpaces(payload.spaces || []);
    store.setBlueprints(payload.blueprints || []);
    store.setSuggestedName(payload.suggested_name);
    // `currentSpaceId` is client-side state. Seed it to the first
    // space (the initial sidebar selection) unless one is already
    // set.
    if (payload.spaces?.length > 0 && store.currentSpaceId == null) {
      store.setCurrentSpaceId(payload.spaces[0].id);
    }
    // `current_user` is the JSON-safe slice the server sends
    // on every lobby init. Overwrite whatever the store has
    // so the UI shows the authoritative name (e.g. after the
    // user changed their password elsewhere).
    if (payload.current_user !== undefined) {
      store.setCurrentUser(payload.current_user);
    }
    // The same payload carries the caller's invites so the
    // InvitesPage has data on first render without a separate
    // fetch. The server's InviteJSON includes the plaintext
    // token (the user can always copy it back).
    if (payload.invites !== undefined) {
      store.setInvites(payload.invites || []);
    }
  });

  // Server-side push when a `create_invite` reply succeeds
  // — prepended to the in-memory list so the InvitesPage
  // reflects the new row without a re-fetch. The server's
  // `invite:created` payload is the full InviteJSON (with
  // token), so the UI can render the new token cell
  // immediately.
  lobbyChannel.on("invite:created", (invite) => {
    const store = getStore();
    store.setInvites([invite, ...store.invites]);
    store.setInvitesError(null);
  });

  // Server-side push when a `revoke_invite` reply succeeds
  // — drops the row from the in-memory list. The payload is
  // `{id}`; matching is on integer id.
  lobbyChannel.on("invite:revoked", (payload) => {
    const store = getStore();
    if (payload?.id !== undefined) {
      store.setInvites(store.invites.filter((i) => i.id !== payload.id));
    }
    store.setInvitesError(null);
  });

  // Follow-up to the initial `init` push. The lobby pushes an
  // empty `broken_agents` list on join (so the WS first-frame
  // is fast even when `Models.list/0` is hung), then computes
  // the real list asynchronously and rebroadcasts here. JS
  // replaces the empty list with whatever comes back (or
  // `[]` again on timeout).
  lobbyChannel.on("broken_agents_updated", (payload) => {
    const store = getStore();
    store.setBrokenAgents(payload.broken_agents || []);
  });

  lobbyChannel.on("agent:created", (payload) => {
    const store = getStore();
    store.addAgent(payload);
  });

  // Broadcast when a space (with its root agent) is created.
  // The payload carries the space struct plus the root agent's
  // name. We append the space to the sidebar list; the matching
  // `agent:created` broadcast (already handled above) adds the
  // root agent to the agents list.
  lobbyChannel.on("space:created", (payload) => {
    const store = getStore();
    if (payload?.space) {
      store.addSpace(payload.space);
    }
  });

  // Broadcast when a user changes an agent's model via
  // `Agents.change_model/2`. The agent's GenServer emits a
  // matching `chat:status` push on the per-agent topic with
  // the new `model` field; this lobby broadcast is the
  // mechanism that lets the sidebar's list also reflect the
  // change without a rejoin.
  lobbyChannel.on("agent:updated", (payload) => {
    const store = getStore();
    if (payload?.name && payload?.model) {
      store.applyAgentModelUpdate(payload.name, payload.model);
    }
  });

  // Follow-up to a `rescan_models` push. The lobby rebroadcasts
  // the merged catalog (static + auto-discovered, with any
  // config.toml changes reloaded server-side) so every client
  // sees the new model list. Both the new-agent form and any
  // open `AgentModelPicker` modal pick up the update via
  // `useStore((state) => state.models)`.
  lobbyChannel.on("models_updated", (payload) => {
    const store = getStore();
    store.setModels(payload.models || []);
  });

  lobbyChannel
    .join()
    .receive("ok", () => {
      if (onOk) onOk();
    })
    .receive("error", (err) => {
      console.error("Lobby channel join error:", err);
      if (onError) onError(err);
    });
}

/**
 * Leave lobby channel
 */
export function leaveLobby() {
  if (lobbyChannel) {
    lobbyChannel.leave();
    lobbyChannel = null;
  }
}

// Per-agent sync state. The inFlight flag is set when a
// `chat:sync` push is in flight and cleared on success. The
// map is cleared per-agent by `leaveAgent`. No coalescing:
// a requestSync call while another is in flight simply
// fires a second push — `syncAgentMessages` is idempotent
// (it merges by index), so duplicate responses don't
// double-add messages. Coalescing is unnecessary for
// correctness; we accept the small bandwidth cost of the
// rare double-push case.
const syncState = new Map(); // agentId -> {inFlight}

/**
 * Request a `chat:sync` for the agent. Pushes the request
 * and updates the cache from the response. Multiple
 * overlapping calls fire multiple pushes (the response
 * merge is idempotent).
 *
 * Callers may pass `{lastIndex: number}` to override the
 * lower bound (e.g. the chat:compaction handler passes
 * `marker.index` so the sync pulls only the new active
 * messages). When `lastIndex` is omitted, the agent's
 * `cache.lastIndex` is used (the highest index the client
 * knows about).
 */
function requestSync(agentId, opts = {}) {
  const cache = getStore().agentsCache[agentId];
  if (!cache) return;

  const lastIndex =
    typeof opts.lastIndex === "number"
      ? opts.lastIndex
      : (cache.lastIndex ?? -1);

  const channel = agentChannels.get(agentId);
  if (!channel) return;

  const previous = syncState.get(agentId) || { inFlight: false };
  syncState.set(agentId, { ...previous, inFlight: true });

  channel.push("chat:sync", { lastIndex }).receive("ok", (resp) => {
    getStore().syncAgentMessages(agentId, resp);
    const current = syncState.get(agentId);
    syncState.set(agentId, { ...current, inFlight: false });
  });
}

// Join agent channel
/**
 * Join agent channel.
 *
 * The backend topic is `agent:<space_id>:<name>`, so the
 * caller must supply the agent's `spaceId` (resolved from the
 * route / store). Idempotent: if already connected, sends a
 * status check.
 */
export function joinAgent(agentId, spaceId) {
  const store = getStore();
  const existingChannel = agentChannels.get(agentId);

  if (existingChannel) {
    existingChannel.push("chat:status", {}).receive("ok", (payload) => {
      store.setAgentConnected(agentId, payload);
      // Re-join via chat:status: the server returns the
      // current `messageCount`. If the server has more active
      // messages than the client, pull the missing ones.
      // Re-read via `getStore()` (the captured `store`
      // is a stale snapshot; `setAgentConnected` mutated
      // the store, so the agent's cache lives on the new
      // state object).
      const cache = getStore().agentsCache[agentId];
      if (
        cache &&
        typeof payload.messageCount === "number" &&
        payload.messageCount > (cache.messages?.length ?? 0)
      ) {
        requestSync(agentId);
      }
    });
    return;
  }

  // Set connecting state
  store.setAgentConnecting(agentId);

  const channel = socket.channel(`agent:${spaceId}:${agentId}`);
  agentChannels.set(agentId, channel);

  // Setup event handlers
  channel.on("init", (payload) => {
    store.setAgentConnected(agentId, payload);
    // The init payload carries the archived `history` and
    // `messageCount`, but not the active messages themselves
    // (the channel serves those on demand via chat:sync). Pull
    // them now so the active area isn't empty. Re-read the
    // store via `getStore()` (the captured `store` is a stale
    // snapshot from `joinAgent`'s call site; `setAgentConnected`
    // mutated the store, so the agent's cache lives on the
    // new state object, not the captured one).
    const cache = getStore().agentsCache[agentId];
    if (
      cache &&
      typeof payload.messageCount === "number" &&
      payload.messageCount > (cache.messages?.length ?? 0)
    ) {
      requestSync(agentId);
    }
  });

  // The backend broadcasts a chat:compaction event when a
  // compaction completes. The payload carries the marker (so the
  // UI can render a divider) and the full archived history. The
  // store replaces the agent's `history` field with the new
  // list, and filters `cache.messages` to drop the just-
  // archived segment (the marker's index is the new boundary).
  // The new active messages (fresh_system, summary_user, …)
  // are NOT broadcast individually by the server, so we follow
  // up with a chat:sync using the marker's index as the lower
  // bound — the response carries exactly the post-swap active
  // list and `syncAgentMessages` merges it into `cache.messages`.
  channel.on("chat:compaction", (payload) => {
    const history = Array.isArray(payload?.history) ? payload.history : [];
    const marker = payload?.marker ?? null;
    store.setAgentHistory(agentId, history, marker);
    if (marker && typeof marker.index === "number") {
      requestSync(agentId, { lastIndex: marker.index });
    }
  });

  // The backend broadcasts a chat:compaction-loop event when
  // the loop-breaker trips (consecutive compactions without
  // progress). The store records the message so the
  // StatusBanner can render the OK button. Distinct from the
  // compaction-failure path (which uses chat:error +
  // agentState="compaction_failed" + a Retry button).
  channel.on("chat:compaction-loop", (payload) => {
    store.setCompactionLoop(agentId, {
      content: payload?.content ?? "compaction isn't reducing the conversation",
      attemptCount: payload?.attemptCount,
      maxAttempts: payload?.maxAttempts,
    });
  });

  channel.on("chat:delta", (delta) => {
    const result = store.addChatDelta(agentId, delta);
    if (result.needsSync) {
      console.warn(
        `[agent:${agentId}] Delta gap at ${delta.charsStart}, expected ${store.agentsCache[agentId]?.partial?.charsReceived || 0}. Syncing.`,
      );
      requestSync(agentId);
    }
  });

  channel.on("chat:error", (error) => {
    // The server broadcasts `chat:error` for two distinct failure
    // shapes: chat-task errors (network/LLM/provider failures) and
    // compaction failures. The compaction path is identified by
    // the `chat:error` payload carrying a `compactionError` marker
    // — see `Broadcasts.error/4` in `lib/nest/agents/agent/broadcasts.ex`
    // and the compaction-failed handler in
    // `lib/nest/agents/agent/handlers/compaction_handler.ex`.
    //
    // We can't tell the two apart from `error.content` alone (both
    // are user-facing strings), so the server also broadcasts a
    // `chat:status` event right after with `status: "compaction_failed"`.
    // The chat:error handler stores the error message; the chat:status
    // handler updates `agentState`. The StatusBanner reads both to
    // render the banner.
    if (error?.compactionError) {
      store.setCompactionError(agentId, error.content);
    } else {
      store.setAgentError(agentId, error.content);
    }

    store.clearPartial(agentId);
    store.setWaitingForResponse(agentId, false);
  });

  channel.on("chat:message", (message) => {
    // `addChatMessage` returns `{applied, needsSync,
    // snapshotLastIndex}`: when a `chat:message` arrives
    // with an index higher than the client's `lastIndex + 1`
    // and the message isn't a reconciliation of an optimistic
    // add, there's a gap in the index sequence (e.g. a
    // `chat:message` was silently lost in transit). Trigger
    // a sync to fill the gap, using the snapshot's
    // `lastIndex` (the pre-update value) as the lower bound
    // so the response includes the missing messages — not
    // just whatever comes after the gap-leader's index.
    const result = store.addChatMessage(agentId, message);
    if (result?.needsSync) {
      const lastIndex =
        typeof result.snapshotLastIndex === "number"
          ? result.snapshotLastIndex
          : undefined;
      requestSync(agentId, { lastIndex });
    }
  });

  channel.on("chat:status", (payload) => {
    // The backend may include the resolved context-window limit and the
    // running usage totals on status pushes (especially the one that
    // follows a successful /models probe and the ones that fire
    // after each LLM response). Forward those fields through
    // `setAgentState`'s extra-arg path so the chip can update live.
    const extra = {};

    if (payload.contextLimit !== undefined) {
      extra.contextLimit = payload.contextLimit;
    }

    if (payload.contextLimitSource !== undefined) {
      extra.contextLimitSource = payload.contextLimitSource;
    }

    if (payload.currentMode !== undefined) {
      // The server includes `currentMode` on every chat:status
      // push so the client can keep the dropdown in sync with
      // the agent's mode (which is updated on each chat send
      // — the "sticky mode" behavior). The ChatPage's
      // `currentMode` React state is updated from this cache
      // value via an effect, so the next message defaults to
      // whatever mode was just used.
      extra.currentMode = payload.currentMode;
    }

    if (payload.usage !== undefined) {
      extra.usage = payload.usage;
    }

    if (payload.parentId !== undefined) {
      extra.parentId = payload.parentId;
    }

    if (payload.parentName !== undefined) {
      extra.parentName = payload.parentName;
    }

    if (payload.depth !== undefined) {
      extra.depth = payload.depth;
    }

    if (payload.descendantUsage !== undefined) {
      extra.descendantUsage = payload.descendantUsage;
    }

    if (payload.totalUsage !== undefined) {
      extra.totalUsage = payload.totalUsage;
    }

    store.setAgentState(agentId, payload.status, extra);

    // When the LLM response completes normally, the agent
    // transitions to :idle. Clear the optimistic "Waiting for
    // response" flag so the chat-level typing indicator
    // disappears.
    //
    // Deltas normally reset it earlier via `addChatDelta`, but
    // thinking-only deltas don't go through the chat:delta
    // broadcast path (see `llm_runner.ex`
    // `forward_thinking_delta/3`) — for a thinking-only
    // response, this is the only reset. We deliberately do NOT
    // reset on "streaming" or "executing_tools": the LLM is
    // still in flight during those states and the indicator
    // should stay visible.
    if (payload.status === "idle") {
      store.setWaitingForResponse(agentId, false);
    }
  });

  channel.on("chat:notification", (payload) => {
    store.setNotification(agentId, payload);
  });

  channel.onClose(() => {
    // Don't set disconnected if join failed (error or timeout)
    // This prevents overwriting error status when Phoenix retries connections
    if (joinFailedAgents.has(agentId)) {
      joinFailedAgents.delete(agentId);
      return;
    }
    // Set disconnected if currently connected (prevents overwriting error status)
    // Must get fresh store state, not use captured 'store' variable
    const currentStore = getStore();
    const cache = currentStore.agentsCache[agentId];
    if (cache?.status === "connected") {
      agentChannels.delete(agentId);
      currentStore.setAgentDisconnected(agentId);
    }
  });

  // Join the channel
  channel
    .join()
    .receive("ok", () => {
      // Wait for init event
    })
    .receive("error", (err) => {
      console.error(`Agent ${agentId} channel join error:`, err);
      joinFailedAgents.add(agentId); // Mark as failed to prevent reconnection
      channel.leave(); // Properly close channel to stop reconnection attempts
      agentChannels.delete(agentId);
      store.setAgentError(agentId, err.reason || "Failed to connect");
    })
    .receive("timeout", () => {
      console.error(`Agent ${agentId} channel join timeout`);
      joinFailedAgents.add(agentId); // Mark as failed to prevent reconnection
      channel.leave(); // Properly close channel to stop reconnection attempts
      agentChannels.delete(agentId);
      store.setAgentError(agentId, "Connection timed out");
    });
}

/**
 * Leave agent channel
 */
export function leaveAgent(agentId) {
  const channel = agentChannels.get(agentId);
  if (channel) {
    channel.leave();
    agentChannels.delete(agentId);
  }
  // Clear any in-flight/queued sync state so a re-join starts
  // with a clean slate.
  syncState.delete(agentId);
}

/**
 * Send chat message to specific agent. The optional `mode` selects
 * the sandbox profile for this message's tool calls. The optional
 * `onError` callback fires when the server rejects the push.
 */
export function sendMessage(agentId, content, mode, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  // Optimistically add user message to cache
  const store = getStore();
  store.addUserMessage(agentId, content, mode);

  const payload = { content };
  if (mode) payload.mode = mode;

  channel
    .push("chat:message", payload)
    .receive("ok", () => {
      // Message acknowledged, waiting for assistant response
      store.setWaitingForResponse(agentId, true);
    })
    .receive("error", (err) => {
      // Clear partial on error
      store.clearPartial(agentId);
      if (onError) onError(err);
    });
}

/**
 * Request that the in-flight chat task for the agent halt
 * immediately. The server finalizes whatever was streamed so
 * far and broadcasts `chat:status: "idle"`. The reply is
 * immediate (`{:ok, %{}}`); the actual stop finalization
 * happens asynchronously. The optional `onError` callback
 * fires when the server rejects the push (e.g. agent not
 * found). A no-op when the channel isn't connected.
 */
export function stopMessage(agentId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel.push("chat:stop", {}).receive("error", (err) => {
    if (onError) onError(err);
  });
}

/**
 * Re-run the compactor after a `chat:error` broadcast for a
 * `:compaction_failed` Agent status. The server replies immediately
 * with `{:ok, %{}}` and broadcasts `chat:status: "compacting"` then
 * eventually `chat:status: "compaction_failed"` (if the retry
 * itself failed) or `chat:status: "idle"` (if it succeeded and the
 * pending user message was appended + a chat turn was spawned).
 *
 * A no-op when the channel isn't connected. The optional `onError`
 * callback fires when the server rejects the push (e.g. agent not
 * found, or agent is not in `:compaction_failed` status).
 */
export function retryCompaction(agentId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel.push("chat:retry-compaction", {}).receive("error", (err) => {
    if (onError) onError(err);
  });
}

/**
 * Acknowledge a `:compaction_loop_detected` status by sending
 * `chat:loop-detected-ok` to the server. The handler transitions
 * the agent back to `:idle` and clears the loop-breaker counter.
 *
 * A no-op when the channel isn't connected. The optional `onError`
 * callback fires when the server rejects the push (e.g. agent not
 * found, or agent is not in `:compaction_loop_detected` status).
 */
export function compactionLoopOk(agentId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel.push("chat:loop-detected-ok", {}).receive("error", (err) => {
    if (onError) onError(err);
  });
}

/**
 * Create a new space (with its root agent) via the lobby.
 * The unit of creation is a space — the lobby's `create_space`
 * push creates the space + root agent in one transaction.
 *
 * `opts` may carry `{ name, slug, blueprint_id, agent_name,
 * workspace_path, shared }`. On success `onOk({ space_id,
 * name })` is called with the new space id and the root agent's
 * name.
 */
export function createSpace(model, vocationId, onOk, onError, opts = {}) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = { model };
  if (vocationId) payload.vocation_id = vocationId;
  if (opts.name) payload.name = opts.name;
  if (opts.slug) payload.slug = opts.slug;
  if (opts.blueprint_id) payload.blueprint_id = opts.blueprint_id;
  if (opts.agent_name) payload.agent_name = opts.agent_name;
  if (opts.workspace_path) payload.workspace_path = opts.workspace_path;
  if (opts.shared) payload.shared = true;

  lobbyChannel
    .push("create_space", payload)
    .receive("ok", (resp) => {
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Ask the lobby for a unique, readable space-name suggestion
 * (adjective-animal, e.g. "clever-raven"). Stores it in
 * `store.suggestedName` (which the new-space form pre-fills) and,
 * when `onOk` is given, also passes the name to it.
 *
 * The initial suggestion arrives with the lobby `init` payload;
 * call this again after a space is created so the next suggestion
 * doesn't collide with the used name.
 */
export function suggestSpaceName(onOk) {
  if (!lobbyChannel) return;
  lobbyChannel.push("suggest_space_name", {}).receive("ok", (resp) => {
    if (resp?.name) {
      getStore().setSuggestedName(resp.name);
      if (onOk) onOk(resp.name);
    }
  });
}

/**
 * Request a server-side rescan of the model catalog. The server
 * replies `:ok` immediately and follows up with a `models_updated`
 * broadcast carrying the merged catalog. Both the new-agent form
 * and any open `AgentModelPicker` modal pick up the new list via
 * the store (no extra wiring).
 *
 * Caller is responsible for tracking loading state — the helper
 * itself is fire-and-forget. Pass `onError` if you want to react
 * to a WS push failure (e.g. the user clicked the button while
 * disconnected).
 */
export function rescanModels(onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("rescan_models", {})
    .receive("ok", () => {
      if (onOk) onOk();
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Change the LLM model of an agent at runtime.
 *
 * `model` is a `{name, provider}` map sourced from the
 * `init.models` payload (or the AgentModelPicker catalog).
 * The lobby broadcast then delivers `agent:updated` to every
 * connected client; the per-agent channel delivers the
 * canonical `chat:status` push with the new `model` field.
 *
 * Distinct error reasons the server can return:
 *   * "agent_busy" — agent is streaming / executing tools;
 *     retry once the next `chat:status: idle` lands.
 *   * "invalid_model" — the provider/model pair can't be
 *     resolved; surface a friendly message in the UI.
 *   * "not_found" — the agent's GenServer is gone (shouldn't
 *     happen normally).
 *   * "invalid_payload" — missing `model.name` / `model.provider`.
 */
export function changeAgentModel(name, spaceId, model, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = {
    name,
    space_id: spaceId,
    model: { name: model.name, provider: model.provider ?? null },
  };

  lobbyChannel
    .push("change_model", payload)
    .receive("ok", () => {
      if (onOk) onOk();
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Issue a fresh invite via the lobby channel. The server
 * replies with `{:ok, invite}` on success and pushes
 * `invite:created` so the in-memory list updates
 * automatically (handled by the `invite:created` listener
 * registered in `joinLobby`). Failure replies are routed
 * to the store as `invitesError`; the channel's
 * `invite:created` push is suppressed on failure.
 *
 * No callback signature — the InvitesPage reads `invites`
 * and `invitesError` from `useStore`. The store is the
 * single source of truth.
 */
export function createInvite() {
  if (!lobbyChannel) {
    useStore.getState().setInvitesError("Not connected to lobby");
    return;
  }

  lobbyChannel.push("create_invite", {}).receive("error", (err) => {
    const message =
      err && typeof err === "object" && "error" in err
        ? err.error
        : "Failed to create invite";
    useStore.getState().setInvitesError(message);
  });
}

/**
 * Revoke an existing invite via the lobby channel. The
 * server replies `:ok` on success and pushes `invite:revoked`
 * so the in-memory list drops the row automatically
 * (handled by the `invite:revoked` listener registered in
 * `joinLobby`). Failure replies are routed to the store as
 * `invitesError`.
 *
 * No callback signature — same contract as `createInvite`.
 */
export function revokeInvite(id) {
  if (!lobbyChannel) {
    useStore.getState().setInvitesError("Not connected to lobby");
    return;
  }

  lobbyChannel.push("revoke_invite", { id }).receive("error", (err) => {
    const message =
      err && typeof err === "object" && "error" in err
        ? err.error
        : "Failed to revoke invite";
    useStore.getState().setInvitesError(message);
  });
}

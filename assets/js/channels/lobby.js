/**
 * Lobby-channel functions: join/leave the lobby and all lobby pushes
 * (space create/archive/unarchive, model change, model rescan, invites).
 * Split from `channels.js` to keep that file under the source-line cap.
 */

import { useStore } from "../store";
import {
  clearLobbyChannel,
  getStore,
  lobbyChannel,
  setLobbyChannel,
  socket,
} from "./state";

/**
 * Join lobby channel
 */
export function joinLobby(onOk, onError) {
  if (lobbyChannel) {
    if (onOk) onOk();
    return;
  }

  setLobbyChannel(socket.channel("lobby"));

  lobbyChannel.on("init", (payload) => {
    const store = getStore();
    store.setAgents(payload.agents || []);
    store.setArchivedAgents(payload.archived_agents || []);
    store.setBrokenAgents(payload.broken_agents || []);
    store.applyAgentStatuses(payload.broken_agents || []);
    store.setModels(payload.models || []);
    store.setVocations(payload.vocations || []);
    store.setProviders(payload.providers || []);
    store.setSpaces(payload.spaces || []);
    store.setArchivedSpaces(payload.archived_spaces || []);
    store.setPausedSpaces(payload.paused_space_ids || []);
    store.setBlueprints(payload.blueprints || []);
    store.setSuggestedName(payload.suggested_name);
    if (payload.current_user !== undefined) {
      store.setCurrentUser(payload.current_user);
    }
    if (payload.invites !== undefined) {
      store.setInvites(payload.invites || []);
    }
  });

  lobbyChannel.on("invite:created", (invite) => {
    const store = getStore();
    store.setInvites([invite, ...store.invites]);
    store.setInvitesError(null);
  });

  lobbyChannel.on("invite:revoked", (payload) => {
    const store = getStore();
    if (payload?.id !== undefined) {
      store.setInvites(store.invites.filter((i) => i.id !== payload.id));
    }
    store.setInvitesError(null);
  });

  lobbyChannel.on("broken_agents_updated", (payload) => {
    const store = getStore();
    store.setBrokenAgents(payload.broken_agents || []);
    store.applyAgentStatuses(payload.broken_agents || []);
  });

  lobbyChannel.on("agent:created", (payload) => {
    getStore().addAgent(payload);
  });

  // A stop is carried as the row's status (#73). The frame is emitted by the
  // agent itself as it dies, so for an archived agent it can arrive *after*
  // `agent:archived` — `markAgentStopped` only touches rows still in the active
  // list, which is what makes that ordering harmless instead of a
  // resurrection.
  lobbyChannel.on("agent:stopped", (payload) => {
    if (payload?.name != null && payload?.space_id != null) {
      getStore().markAgentStopped(payload);
    }
  });

  lobbyChannel.on("agent:archived", (payload) => {
    if (payload?.name != null && payload?.space_id != null) {
      getStore().archiveAgent(payload);
    }
  });

  lobbyChannel.on("agent:unarchived", (payload) => {
    if (payload?.name != null && payload?.space_id != null) {
      getStore().unarchiveAgent(payload);
    }
  });

  lobbyChannel.on("space:created", (payload) => {
    if (payload?.space) {
      getStore().addSpace(payload.space);
    }
  });

  lobbyChannel.on("space:archived", (payload) => {
    if (payload?.space_id != null) {
      getStore().archiveSpace(payload.space_id);
    }
  });

  // An environment edit is in progress, so the space's work is held: turns and
  // tool calls wait until it finishes. Every session that can see the space gets
  // this, which is what lets a second browser show the banner.
  lobbyChannel.on("space:paused", (payload) => {
    if (payload?.space_id != null) {
      getStore().setSpacePaused(payload.space_id, true);
    }
  });

  lobbyChannel.on("space:resumed", (payload) => {
    if (payload?.space_id != null) {
      getStore().setSpacePaused(payload.space_id, false);
    }
  });

  // A space's environment was edited. The frame carries the *whole* space (the
  // server broadcasts the row), so the store replaces its copy rather than
  // patching one field — another session of the same user then shows every
  // edited value, not just the one it knows about.
  lobbyChannel.on("space:updated", (payload) => {
    const space = payload?.space;
    if (space?.id != null) {
      getStore().updateSpace(space);
    }
  });

  lobbyChannel.on("space:unarchived", (payload) => {
    if (payload?.space_id != null) {
      getStore().unarchiveSpace(payload.space_id);
    }
  });

  lobbyChannel.on("agent:updated", (payload) => {
    const store = getStore();
    if (payload?.name && payload?.model) {
      store.applyAgentModelUpdate(payload.name, payload.model);
    }
  });

  // A space-scoped status frame (#53). Only spaces this client is
  // subscribed to deliver it, so a frame for an unknown agent is a no-op.
  lobbyChannel.on("agent:status", (payload) => {
    if (
      payload?.name != null &&
      payload?.space_id != null &&
      payload?.status != null
    ) {
      getStore().applyAgentStatus(payload);
    }
  });

  // One note with a human at one end (`Nest.Notes`), which every `user_notes`
  // insert broadcasts on its space's topic — the topic this channel subscribed
  // to for every space the user can see, so a frame for another space never
  // arrives. The server has already dropped a note between two other humans
  // (`Nest.Notes.for_user?/2`); the feed's store keeps it if that space's feed
  // is open, and drops it otherwise (its next read fetches the whole list).
  lobbyChannel.on("user_note:created", (payload) => {
    if (payload?.note) {
      getStore().appendSpaceNote(payload.note);
    }
  });

  lobbyChannel.on("models_updated", (payload) => {
    getStore().setModels(payload.models || []);
  });

  lobbyChannel.on("providers_updated", (payload) => {
    getStore().setProviders(payload.providers || []);
  });

  // Cache stats are broadcast by every `clear_probe_cache` (so a second
  // admin's clear refreshes this GUI too) and are also carried by the
  // replies to `probe_cache_stats` / `clear_probe_cache`.
  lobbyChannel.on("probe_cache_stats", (payload) => {
    getStore().setProbeCacheStats(payload?.stats);
  });

  lobbyChannel
    .join()
    .receive("ok", () => {
      // The server answers lobby pushes only from here on: a page whose first
      // read is one of them waits for this flag (`SpaceFeed`).
      getStore().setLobbyJoined(true);
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
    clearLobbyChannel();
    getStore().setLobbyJoined(false);
  }
}

/**
 * Create a new space (with its root agent) via the lobby.
 */
export function createSpace(model, vocationSlug, onOk, onError, opts = {}) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = { model };
  if (vocationSlug) payload.vocation = vocationSlug;
  if (opts.name) payload.name = opts.name;
  if (opts.slug) payload.slug = opts.slug;
  if (opts.blueprint_id) payload.blueprint_id = opts.blueprint_id;
  if (opts.agent_name) payload.agent_name = opts.agent_name;
  if (typeof opts.network_access === "boolean") {
    payload.network_access = opts.network_access;
  }
  if (opts.sandbox_backend) payload.sandbox_backend = opts.sandbox_backend;
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
 * Archive a space (hide it from the main space list).
 */
export function archiveSpace(spaceId, onOk, onError) {
  if (!lobbyChannel) return;
  lobbyChannel
    .push("archive_space", { space_id: spaceId })
    .receive("ok", (resp) => {
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Edit a space's **environment**: its workspace, its network access and its
 * sandbox backend.
 *
 * One push for all three because they are one decision: every agent in the
 * space inherits them, and the server tells the live ones about the change
 * (`Agent.space_changed/2`). Nothing is restarted; a *backend* change releases
 * this space's container, so its agents' `/tmp` (offloads, background-job logs)
 * and any running background job go with it — the dialog says so before the
 * save.
 *
 * The reply is the environment that is now in force, with string keys. The
 * whole space arrives separately, as a `space:updated` frame, and that is what
 * updates the store.
 */
export function editSpace(spaceId, values, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = {
    space_id: spaceId,
    workspace_path: values.workspace_path,
    network_access: values.network_access,
    sandbox_backend: values.sandbox_backend,
  };

  // The second push of a two-phase edit: the user has seen what the first one
  // would stop and said yes. Absent on the first push, which is what makes the
  // server answer `confirmation_required` rather than saving.
  if (values.confirm) payload.confirm = true;

  lobbyChannel
    .push("edit_space", payload)
    .receive("ok", (resp) => {
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Say no to a space edit, releasing the pause the preview took.
 *
 * The first `edit_space` push holds the space's latch (`Nest.Agents.SpaceGate`)
 * so nothing can start in it while the user decides. Cancelling is therefore not
 * just "close the dialog": it has to tell the server, or the space stays paused
 * until the claim's TTL expires. The server releases only a claim this session
 * owns, so a stray push cannot unpause another session's edit.
 */
export function cancelEditSpace(spaceId, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("cancel_edit_space", { space_id: spaceId })
    .receive("ok", (resp) => {
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Restore an archived space to the main space list.
 */
export function unarchiveSpace(spaceId, onOk, onError) {
  if (!lobbyChannel) return;
  lobbyChannel
    .push("unarchive_space", { space_id: spaceId })
    .receive("ok", (resp) => {
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Restore an archived agent to its space's active list.
 */
export function unarchiveAgent(name, spaceId, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("unarchive_agent", { name, space_id: spaceId })
    .receive("ok", (resp) => {
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Ask the lobby for a unique, readable space-name suggestion.
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
 * Request a server-side rescan of the model catalog.
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
 * Save the configured providers/models to `local.toml` (admin-only
 * server-side). `providers` is the full list of provider maps the GUI
 * edits; the server persists it and broadcasts `providers_updated` +
 * `models_updated` on success.
 */
export function saveProviders(providers, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("save_providers", { providers })
    .receive("ok", () => {
      if (onOk) onOk();
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Ask the lobby for the multimodal probe cache's stats (admin-only
 * server-side). The reply carries `{entries, oldest_age_s, path}`; it is
 * stored rather than handed back, so the page reads one source of truth
 * (`probeCacheStats`) whether the stats arrived as a reply or as a
 * broadcast.
 */
export function requestProbeCacheStats(onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("probe_cache_stats", {})
    .receive("ok", (resp) => {
      getStore().setProbeCacheStats(resp?.stats);
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Clear the persisted multimodal probe cache (admin-only server-side,
 * idempotent). The reply carries the post-clear stats and the lobby
 * broadcasts them to every session; a reply without stats stores `null`
 * so the GUI says "state unknown" instead of leaving pre-clear numbers
 * on screen for a cache that is now empty.
 *
 * Nothing about a scan in flight is touched: a verdict a probe settles
 * after the clear is written normally.
 */
export function clearProbeCache(onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("clear_probe_cache", {})
    .receive("ok", (resp) => {
      getStore().setProbeCacheStats(resp?.stats);
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Change the LLM model of an agent at runtime.
 */
export function changeAgentModel(name, spaceId, model, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = {
    name,
    space_id: spaceId,
    model: {
      name: model.name,
      provider: model.provider ?? null,
      thinking_level: model.thinking_level ?? null,
    },
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
 * Edit an agent's model (and thinking level) via the lobby's `edit_agent`
 * action. The working directory is not here: a workspace is a *space*
 * property, so it is edited on the space.
 */
export function editAgent(name, spaceId, model, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = {
    name,
    space_id: spaceId,
    model: {
      name: model.name,
      provider: model.provider ?? null,
      thinking_level: model.thinking_level ?? null,
    },
  };

  lobbyChannel
    .push("edit_agent", payload)
    .receive("ok", () => {
      if (onOk) onOk();
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Issue a fresh invite via the lobby channel. No callback signature —
 * the InvitesPage reads `invites` / `invitesError` from `useStore`.
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
 * Revoke an existing invite via the lobby channel.
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

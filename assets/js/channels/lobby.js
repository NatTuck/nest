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

  lobbyChannel.on("space:updated", (payload) => {
    const space = payload?.space;
    if (space?.id != null && typeof space.network_access === "boolean") {
      getStore().setSpaceNetworkAccess(space.id, space.network_access);
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
    if (payload?.name && payload?.workspace_path !== undefined) {
      store.applyAgentWorkspaceUpdate(payload.name, payload.workspace_path);
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
  if (opts.workspace_path) payload.workspace_path = opts.workspace_path;
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
 * Turn a space's network access on or off. It is a space property, editable
 * after creation, and it takes effect for the space's agents' subsequent
 * commands.
 */
export function setSpaceNetwork(spaceId, networkAccess, onOk, onError) {
  if (!lobbyChannel) return;
  lobbyChannel
    .push("set_space_network", {
      space_id: spaceId,
      network_access: networkAccess,
    })
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
 * Edit an agent's model (and thinking level) and working directory
 * in a single lobby `edit_agent` action.
 */
export function editAgent(name, spaceId, model, workspacePath, onOk, onError) {
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
    workspace_path: workspacePath ?? null,
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

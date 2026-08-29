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
    store.setBrokenAgents(payload.broken_agents || []);
    store.setModels(payload.models || []);
    store.setVocations(payload.vocations || []);
    store.setProviders(payload.providers || []);
    store.setSpaces(payload.spaces || []);
    store.setArchivedSpaces(payload.archived_spaces || []);
    store.setBlueprints(payload.blueprints || []);
    store.setSuggestedName(payload.suggested_name);
    if (payload.spaces?.length > 0 && store.currentSpaceId == null) {
      store.setCurrentSpaceId(payload.spaces[0].id);
    }
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
  });

  lobbyChannel.on("agent:created", (payload) => {
    getStore().addAgent(payload);
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

  lobbyChannel.on("models_updated", (payload) => {
    getStore().setModels(payload.models || []);
  });

  lobbyChannel.on("providers_updated", (payload) => {
    getStore().setProviders(payload.providers || []);
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

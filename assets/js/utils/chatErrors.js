/**
 * The workspace refusals the *space* create and edit paths can carry. Returns
 * `null` for any other reason.
 *
 * Only the space paths have them: a workspace is a space property, so an agent
 * edit cannot produce one (`LobbyChannel`'s `edit_agent` neither takes nor
 * validates a workspace). The wording therefore names the *space*, not the
 * agent — "a working directory is required for this space".
 */
function describeWorkspaceError(reason) {
  switch (reason) {
    case "workspace_required":
      // The space's, not the agent's: this reason comes from the space create
      // and edit paths, where the workspace belongs to the space every agent in
      // it inherits.
      return "A working directory is required for this space.";
    case "workspace_missing":
      return "That working directory doesn't exist on the server.";
    case "workspace_under_tmp":
      return "The working directory can't be under /tmp. Choose a directory outside /tmp.";
    default:
      return null;
  }
}

/**
 * A `.nest` or `AGENTS.md` that is not a regular file cannot be masked, and a
 * mask that is merely omitted lets an agent replace the file with one that
 * grants host access (`.nest`) or changes another agent's prompt (`AGENTS.md`).
 * So the workspace is refused until it is a regular file. Not "is a symlink":
 * the reason fires for a directory, a fifo, a hardlink or an unreadable path
 * too, so the sentence must not name a type it was not told. Returns `null`
 * for any other reason.
 *
 * The single wording for this refusal: `describeEditError`,
 * `describeCreateError` and `errorText` (the send and channel-join paths) all
 * call it, so the three cannot drift apart.
 */
export function describeConfigFileError(err) {
  if (err?.reason !== "config_file_not_regular") return null;

  // The one type the generic sentence would be false about: a hardlink *is* a
  // regular file. It is refused because writing the other name rewrites this
  // one, so the remedy is not `cp` — copying over it leaves two names on the
  // inode — but removing the other name.
  if (err?.type === "hardlink") {
    return err?.path
      ? `${err.path} has more than one name on disk, so Nest can't protect it — writing the other name rewrites it. Remove the other name (or delete the file and copy it back) and try again.`
      : "A .nest or AGENTS.md in that workspace has more than one name on disk, so Nest can't protect it — writing the other name rewrites it. Remove the other name and try again.";
  }

  return err?.path
    ? `${err.path} is not a regular file. Nest can't protect it from being rewritten, so it must be a regular file — copy the file into the workspace instead of linking it.`
    : "A .nest or AGENTS.md in that workspace is not a regular file. Nest can't protect it from being rewritten, so it must be a regular file — copy the file into the workspace instead of linking it.";
}

/**
 * Map an `edit_agent` error reply to a user-friendly message. The reply is
 * `{reason: <code>, path?: <path>, type?: <type>}` — the whole payload, not a
 * bare reason string, because some reasons need the `path` (and the config-file
 * refusal needs the `type`) — mirroring the `:reply` payload from
 * `LobbyChannel.handle_in("edit_agent", …)`.
 */
export function describeEditError(err) {
  const reason = err?.reason;

  const configFile = describeConfigFileError(err);
  if (configFile) return configFile;

  const workspace = describeWorkspaceError(reason);
  if (workspace) return workspace;

  switch (reason) {
    case "agent_busy":
      return "Agent is busy. Wait for the current chat to finish before editing.";
    case "invalid_model":
      return "That model isn't configured on the server.";
    case "context_overflow":
      return "The conversation is too full to record the change. Compact or start a new session.";
    case "not_found":
      return "Agent not found. Refresh the page and try again.";
    case "invalid_payload":
      return "Couldn't read the edit. Try again.";
    default:
      return reason
        ? `Failed to edit agent: ${reason}`
        : "Failed to edit agent.";
  }
}

/**
 * Map an `edit_space` error reply to a user-friendly message. The reply is
 * `{reason: <code>, path?: <path>, type?: <type>}` — the whole payload, because
 * the config-file refusal needs the `path` (and its `type`) — mirroring the
 * `:reply` payload from `LobbyChannel.handle_in("edit_space", …)`.
 *
 * The shared refusals (`workspace_*`, the config-file one) are worded by the
 * same helpers the create and edit-agent paths use, so the three cannot drift.
 */
export function describeSpaceEditError(err) {
  const reason = err?.reason;

  const configFile = describeConfigFileError(err);
  if (configFile) return configFile;

  const workspace = describeWorkspaceError(reason);
  if (workspace) return workspace;

  switch (reason) {
    case "invalid_sandbox_backend":
      // The server validates the backend by *value*, so this is a choice the
      // user just made, not a failed request.
      return "That sandbox backend isn't one this server implements.";
    case "not_found":
      return "Space not found. Refresh the page and try again.";
    case "space_changing":
      // Another session is editing this space: its edit holds the space paused,
      // and only one edit may run at a time. Nothing is wrong with *this* save —
      // it just has to wait for that one to finish. It is also what a socket that
      // reconnected between the preview and the confirmation sees (the claim
      // belongs to the channel process that took it, and the new one is a
      // different caller), so the message must not name a second person.
      return "Another session is editing this space — possibly this one, if the page reconnected. Try again once that edit finishes.";
    case "invalid_payload":
      return "Couldn't read the edit. Try again.";
    default:
      return reason
        ? `Failed to save the space: ${reason}`
        : "Failed to save the space.";
  }
}

/**
 * Map a `create_space` error reply to a user-friendly message. The reply is
 * `{reason: <code>, path?: <path>, type?: <type>}` (mirroring the `:reply`
 * reasons from `LobbyChannel.handle_in("create_space", …)`); an `Error` object
 * still falls through to its `message`.
 */
export function describeCreateError(err) {
  const reason = err?.reason;

  const configFile = describeConfigFileError(err);
  if (configFile) return configFile;

  const workspace = describeWorkspaceError(reason);
  if (workspace) return workspace;

  switch (reason) {
    case "blueprint_missing":
      return "That blueprint no longer exists. Pick another one.";
    case "vocation_not_found":
      return "That blueprint's root agent vocation no longer exists. Pick another blueprint.";
    case "missing_vocation":
      return "No agent vocation is configured on the server.";
    case "invalid_agent_name":
      return "Agent names can only contain letters, numbers, dashes and underscores.";
    case "scratch_path_taken":
      // The name is free, but the host directory Nest would use for this
      // agent's scratch already exists and is not Nest's — so Nest will not
      // adopt it (and would refuse to remove it later). Only a `none`-backend
      // space can hit this: it is the one that puts its agents in the host /tmp.
      return err?.path
        ? `There is already something at ${err.path} on the server, and it is not this space's. Pick another agent name.`
        : "There is already something at that agent's scratch path on the server. Pick another agent name.";
    case "scratch_name_in_use":
      // A `none`-backend space runs commands on the host, so its agents'
      // scratch directories all live under the one host `/tmp`. Two such
      // spaces can therefore never share an agent name.
      return err?.space_name
        ? `Space "${err.space_name}" already uses that agent name. Spaces with the "none" sandbox backend share the host /tmp, so their names must be unique across them.`
        : 'That agent name is already used by a space with the "none" sandbox backend. Those spaces share the host /tmp, so their names must be unique across them.';
    default:
      return err?.message || "Failed to create space.";
  }
}

/**
 * Human-readable status label for the agent header status dot.
 */
export function getStatusLabel(
  status,
  streaming,
  executingTools,
  waitingForResponse,
  compacting,
) {
  if (status !== "connected") return status;
  if (compacting) return "Compacting conversation…";
  if (streaming) return "Generating response";
  if (executingTools) return "Executing tools";
  if (waitingForResponse) return "Waiting for response";
  return "Ready";
}

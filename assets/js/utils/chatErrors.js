/**
 * The workspace refusals the edit-agent and create-space paths share, so the
 * two answer with one wording. Returns `null` for any other reason.
 */
function describeWorkspaceError(reason) {
  switch (reason) {
    case "workspace_required":
      return "A working directory is required for this agent.";
    case "workspace_missing":
      return "That working directory doesn't exist on the server.";
    case "workspace_under_tmp":
      return "The working directory can't be under /tmp. Choose a directory outside /tmp.";
    default:
      return null;
  }
}

/**
 * Map the `edit_agent` server error-reason string to a user-friendly
 * message. Each branch mirrors a `:reply` reason from
 * `LobbyChannel.handle_in("edit_agent", …)`.
 */
export function describeEditError(reason) {
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
 * Map a `create_space` error reply to a user-friendly message. The reply is
 * `{reason: <code>}` (mirroring the `:reply` reasons from
 * `LobbyChannel.handle_in("create_space", …)`); an `Error` object still falls
 * through to its `message`.
 */
export function describeCreateError(err) {
  const reason = err?.reason;

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
    case "config_file_not_regular":
      // A `.nest` or `AGENTS.md` that is a symlink cannot be masked, and a mask
      // that is merely omitted lets an agent replace the file with one that
      // grants host access (`.nest`) or changes another agent's prompt
      // (`AGENTS.md`). So the workspace is refused until it is a regular file.
      return err?.path
        ? `${err.path} is a symlink. Nest can't protect a symlink from being rewritten, so it must be a regular file — copy the file into the workspace instead of linking it.`
        : "A .nest or AGENTS.md in that workspace is a symlink. Nest can't protect a symlink from being rewritten, so it must be a regular file — copy the file into the workspace instead of linking it.";
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

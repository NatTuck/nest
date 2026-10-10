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

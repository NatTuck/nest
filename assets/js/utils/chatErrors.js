/**
 * Map the `edit_agent` server error-reason string to a user-friendly
 * message. Each branch mirrors a `:reply` reason from
 * `LobbyChannel.handle_in("edit_agent", …)`.
 */
export function describeEditError(reason) {
  switch (reason) {
    case "agent_busy":
      return "Agent is busy. Wait for the current chat to finish before editing.";
    case "invalid_model":
      return "That model isn't configured on the server.";
    case "workspace_required":
      return "A working directory is required for this agent.";
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

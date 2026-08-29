/**
 * Wrapper around `EditAgentDialog` that builds the `current` props map
 * for the agent being edited. Extracted from `ChatPage`.
 */

import { EditAgentDialog } from "./EditAgentDialog";
import { vocationRequiresWorkspace } from "../utils/vocationWorkspace";

export function AgentEditModal({
  open,
  onClose,
  onSave,
  model,
  workspace_path,
  vocation,
}) {
  const current = {
    name: model?.name ?? null,
    provider: model?.provider ?? null,
    thinking_level: model?.thinking_level ?? null,
    workspace_path,
    requires_workspace: vocationRequiresWorkspace(vocation),
  };

  return (
    <EditAgentDialog
      open={open}
      onClose={onClose}
      current={current}
      onSave={onSave}
    />
  );
}

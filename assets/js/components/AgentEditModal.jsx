/**
 * Wrapper around `EditAgentDialog` that builds the `current` props map
 * for the agent being edited. Extracted from `ChatPage`.
 */

import { EditAgentDialog } from "./EditAgentDialog";

export function AgentEditModal({ open, onClose, onSave, model }) {
  const current = {
    name: model?.name ?? null,
    provider: model?.provider ?? null,
    thinking_level: model?.thinking_level ?? null,
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

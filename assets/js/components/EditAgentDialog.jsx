/**
 * EditAgentDialog — modal form for editing an active agent.
 *
 * Replaces the old "Pick a model" picker. Lets the user change the
 * agent's model (with thinking level) and, for workspace-requiring
 * vocations, its working directory. A single Save emits one
 * `edit_agent` channel action; Reset reverts the form to the agent's
 * current values.
 *
 * Used by:
 *   - ChatPage header chip (always available)
 *   - ChatPage :model_missing repair banner
 *
 * Props:
 *   - `open`      — show/hide the modal.
 *   - `onClose`   — close the modal (Escape / backdrop / X).
 *   - `current`   — `{ name, provider, thinking_level, workspace_path,
 *                    requires_workspace }` — the agent's saved values,
 *                    used to initialize the form and for Reset.
 *   - `onSave`    — `({ model, workspace_path }) => void`, called when
 *                    the user clicks Save.
 */

import { useEffect, useState } from "react";
import { useStore } from "../store";

const DEFAULT_THINKING_LEVELS = ["off", "low", "medium", "high", "xhigh"];

export function EditAgentDialog({ open, onClose, current, onSave }) {
  const models = useStore((state) => state.models);

  const [selectedName, setSelectedName] = useState("");
  const [selectedThinking, setSelectedThinking] = useState("medium");
  const [workspace, setWorkspace] = useState("");
  const [saveError, setSaveError] = useState(null);

  // Initialize the form from the agent's current values whenever the
  // modal opens.
  useEffect(() => {
    if (open) {
      setSelectedName(current?.name ?? "");
      setSelectedThinking(current?.thinking_level ?? "medium");
      setWorkspace(current?.workspace_path ?? "");
      setSaveError(null);
    }
  }, [open, current]);

  if (!open) {
    return null;
  }

  const requiresWorkspace = !!current?.requires_workspace;
  const hasWorkspace = !!current?.workspace_path;
  // Show the field whenever the vocation needs a workspace OR the agent
  // already has one, so an agent that definitely has a working directory
  // always exposes it (even if its vocation modes aren't available).
  const showWorkspace = requiresWorkspace || hasWorkspace;

  const selectedModel = models.find((m) => m.name === selectedName);
  const thinkingOptions = selectedModel?.thinking_levels?.length
    ? selectedModel.thinking_levels
    : DEFAULT_THINKING_LEVELS;

  const handleReset = () => {
    setSelectedName(current?.name ?? "");
    setSelectedThinking(current?.thinking_level ?? "medium");
    setWorkspace(current?.workspace_path ?? "");
    setSaveError(null);
  };

  const handleSave = () => {
    if (!selectedName) {
      setSaveError("Please select a model.");
      return;
    }
    if (requiresWorkspace && !workspace?.trim()) {
      setSaveError("Please specify a working directory.");
      return;
    }

    const nextWorkspace = showWorkspace ? workspace.trim() : null;

    onSave({
      model: {
        name: selectedName,
        provider: selectedModel?.provider ?? current?.provider ?? null,
        thinking_level: selectedThinking,
      },
      workspace_path: nextWorkspace,
    });
  };

  const handleKeyDown = (e) => {
    if (e.key === "Escape") onClose();
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Edit agent"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
      onKeyDown={handleKeyDown}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Edit agent</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="text-gray-400 hover:text-gray-600 transition-colors p-1"
          >
            <svg
              className="w-5 h-5"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>

        <div className="px-6 py-4 space-y-4">
          <div>
            <label
              htmlFor="edit-model-select"
              className="block text-sm font-medium text-gray-700 mb-1"
            >
              Model
            </label>
            <select
              id="edit-model-select"
              value={selectedName}
              onChange={(e) => {
                setSelectedName(e.target.value);
                // Reset the thinking level on a model change so a
                // stale choice isn't carried over.
                setSelectedThinking("medium");
              }}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
            >
              <option value="">Choose a model...</option>
              {models.map((model) => (
                <option key={model.name} value={model.name}>
                  {model.name}
                  {model.provider ? ` (${model.provider})` : ""}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label
              htmlFor="edit-thinking-select"
              className="block text-sm font-medium text-gray-700 mb-1"
            >
              Thinking Level
            </label>
            <select
              id="edit-thinking-select"
              value={selectedThinking}
              onChange={(e) => setSelectedThinking(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
            >
              {thinkingOptions.map((level) => (
                <option key={level} value={level}>
                  {level}
                </option>
              ))}
            </select>
          </div>

          {showWorkspace && (
            <div>
              <label
                htmlFor="edit-workspace-input"
                className="block text-sm font-medium text-gray-700 mb-1"
              >
                Working Directory
              </label>
              <input
                id="edit-workspace-input"
                type="text"
                value={workspace}
                onChange={(e) => setWorkspace(e.target.value)}
                placeholder="/path/to/workspace"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
              />
            </div>
          )}

          {saveError && (
            <p className="text-sm text-red-600" role="alert">
              {saveError}
            </p>
          )}
        </div>

        <div className="px-6 py-4 border-t border-gray-200 bg-gray-50 flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={handleReset}
            className="px-4 py-2 rounded-lg text-sm font-medium text-gray-700 hover:bg-gray-200 transition-colors"
          >
            Reset
          </button>
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 rounded-lg text-sm font-medium text-gray-600 hover:bg-gray-100 transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSave}
            className="px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors"
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}

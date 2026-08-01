/**
 * New Agent Page - Form to create a new agent.
 *
 * Features:
 * - Model selection dropdown
 * - Vocation selection dropdown
 * - Workspace path input (for Programmer vocation)
 * - Create Agent button
 * - Loading state
 * - Navigate to new agent on success
 */

import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useStore } from "../store";
import { createAgent, rescanModels } from "../channels";

/**
 * Validate the new-agent form before firing the lobby push.
 * Returns the user-facing error message, or `null` when the
 * form is submittable. Pure function — extracted from
 * `handleCreateAgent` so the conditional branches are
 * unit-testable without spinning up React.
 *
 * @param {object} params
 * @param {string} params.selectedModel — the model `<select>` value.
 * @param {string} params.selectedVocation — the vocation `<select>` value.
 * @param {boolean} params.requiresWorkspace — true when the
 *   chosen vocation is the Programmer (which requires a path).
 * @param {string} params.workspacePath — the workspace text input.
 * @returns {string | null} the validation error, or `null`.
 */
export function validateNewAgentForm({
  selectedModel,
  selectedVocation,
  requiresWorkspace,
  workspacePath,
}) {
  if (!selectedModel) {
    return "Please select a model";
  }
  if (!selectedVocation) {
    return "Please select a vocation";
  }
  if (requiresWorkspace && !workspacePath) {
    return "Please specify a workspace path for the Programmer vocation";
  }
  return null;
}

/**
 * New Agent Page component
 */
export function NewAgentPage() {
  const navigate = useNavigate();
  const { models, vocations } = useStore();
  const [selectedModel, setSelectedModel] = useState("");
  const [selectedVocation, setSelectedVocation] = useState("");
  const [workspacePath, setWorkspacePath] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState(null);
  const [isRescanning, setIsRescanning] = useState(false);

  // Reset the rescan spinner when the merged catalog lands.
  // The `rescan_models` push reply is `:ok`; the real catalog
  // arrives via the follow-up `models_updated` broadcast which
  // mutates `store.models`. Comparing the array reference (the
  // store replaces the whole array on each `setModels`) is
  // enough to know the round-trip completed.
  const lastModelsRef = useRef(models);

  useEffect(() => {
    if (lastModelsRef.current !== models && isRescanning) {
      lastModelsRef.current = models;
      setIsRescanning(false);
    }
  }, [models, isRescanning]);

  const selectedVocationData = vocations?.find(
    (v) => v.id.toString() === selectedVocation,
  );
  const requiresWorkspace = selectedVocationData?.name === "Programmer";

  const handleCreateAgent = () => {
    const validationError = validateNewAgentForm({
      selectedModel,
      selectedVocation,
      requiresWorkspace,
      workspacePath,
    });

    if (validationError) {
      setError(validationError);
      return;
    }

    setIsCreating(true);
    setError(null);

    const model = models.find((m) => m.name === selectedModel) || {
      name: selectedModel,
    };

    const vocationId = parseInt(selectedVocation, 10);
    const workspace = requiresWorkspace ? workspacePath : null;

    createAgent(
      model,
      vocationId,
      workspace,
      (name) => {
        navigate(`/agent/${name}`);
      },
      (err) => {
        setError(err.message || "Failed to create agent");
        setIsCreating(false);
      },
    );
  };

  const handleRescanModels = () => {
    setIsRescanning(true);
    rescanModels(
      () => {
        // The actual catalog lands via the `models_updated`
        // broadcast → `setModels` in the store. We don't get
        // a per-payload hook, so use a small effect on the
        // store's last-applied index to clear `isRescanning`
        // (see below).
      },
      (err) => {
        setIsRescanning(false);
        setError(err?.message || "Failed to rescan providers");
      },
    );
  };

  return (
    <div className="max-w-2xl mx-auto py-12">
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">
          Create New Agent
        </h1>
        <p className="text-gray-600 mb-8">
          Select a model and vocation to spawn a new AI agent.
        </p>

        {/* Error message */}
        {error && (
          <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-lg">
            <p className="text-red-700">{error}</p>
          </div>
        )}

        {/* Vocation selection */}
        <div className="mb-6">
          <label
            htmlFor="vocation-select"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Select Vocation
          </label>
          <select
            id="vocation-select"
            value={selectedVocation}
            onChange={(e) => setSelectedVocation(e.target.value)}
            className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
            disabled={isCreating}
          >
            <option value="">Choose a vocation...</option>
            {(vocations || []).map((vocation) => (
              <option key={vocation.id} value={vocation.id}>
                {vocation.name}
              </option>
            ))}
          </select>
          {selectedVocationData && (
            <p className="mt-2 text-sm text-gray-600">
              {selectedVocationData.description}
            </p>
          )}
        </div>

        {/* Workspace path input (for Programmer) */}
        {requiresWorkspace && (
          <div className="mb-6">
            <label
              htmlFor="workspace-path"
              className="block text-sm font-medium text-gray-700 mb-2"
            >
              Workspace Path
            </label>
            <input
              id="workspace-path"
              type="text"
              value={workspacePath}
              onChange={(e) => setWorkspacePath(e.target.value)}
              placeholder="/path/to/project"
              className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
              disabled={isCreating}
            />
            <p className="mt-2 text-sm text-gray-500">
              The Programmer vocation needs a workspace directory to read and
              write files.
            </p>
          </div>
        )}

        {/* Model selection */}
        <div className="mb-6">
          <div className="flex items-end justify-between mb-2 gap-3">
            <label
              htmlFor="model-select"
              className="block text-sm font-medium text-gray-700"
            >
              Select Model
            </label>
            <button
              type="button"
              onClick={handleRescanModels}
              disabled={isRescanning || isCreating}
              aria-label="Rescan providers"
              className={`
                inline-flex items-center gap-2 px-3 py-1.5 rounded-md
                text-xs font-medium border transition-all
                ${
                  isRescanning || isCreating
                    ? "bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed"
                    : "bg-amber-50 text-amber-800 border-amber-200 hover:bg-amber-100 hover:border-amber-300 active:bg-amber-200"
                }
              `}
            >
              {isRescanning ? (
                <>
                  <svg
                    className="animate-spin h-3.5 w-3.5"
                    fill="none"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                  >
                    <circle
                      className="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="4"
                    />
                    <path
                      className="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    />
                  </svg>
                  Rescanning…
                </>
              ) : (
                "Rescan providers"
              )}
            </button>
          </div>
          <select
            id="model-select"
            value={selectedModel}
            onChange={(e) => setSelectedModel(e.target.value)}
            className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
            disabled={isCreating}
          >
            <option value="">Choose a model...</option>
            {models.length > 0 ? (
              models.map((model) => (
                <option key={model.name} value={model.name}>
                  {model.name}
                  {model.provider ? ` (${model.provider})` : ""}
                </option>
              ))
            ) : (
              <option value="gpt-4">gpt-4 (fallback)</option>
            )}
          </select>
          {models.length === 0 && (
            <p className="mt-2 text-sm text-amber-600">
              No models configured. Using fallback option.
            </p>
          )}
        </div>

        {/* Create button */}
        <button
          type="button"
          onClick={handleCreateAgent}
          disabled={isCreating || !selectedModel || !selectedVocation}
          className={`
            w-full py-3 px-4 rounded-lg font-semibold text-white
            transition-all duration-200
            ${
              isCreating || !selectedModel || !selectedVocation
                ? "bg-gray-400 cursor-not-allowed"
                : "bg-blue-600 hover:bg-blue-700 active:bg-blue-800"
            }
          `}
        >
          {isCreating ? (
            <span className="flex items-center justify-center gap-2">
              <svg
                className="animate-spin h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                aria-label="Loading spinner"
              >
                <circle
                  className="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  strokeWidth="4"
                />
                <path
                  className="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                />
              </svg>
              Creating Agent...
            </span>
          ) : (
            "Create Agent"
          )}
        </button>

        {/* Info box */}
        <div className="mt-8 p-4 bg-gray-50 rounded-lg">
          <h3 className="font-semibold text-gray-700 mb-2">
            What is a Vocation?
          </h3>
          <p className="text-sm text-gray-600">
            A vocation defines an agent&apos;s role, capabilities, and
            permissions. Different vocations have access to different tools and
            can operate in different modes. For example, the Programmer vocation
            can read and write files in a workspace, while Chat Buddy is for
            general conversation.
          </p>
        </div>
      </div>
    </div>
  );
}

export default NewAgentPage;

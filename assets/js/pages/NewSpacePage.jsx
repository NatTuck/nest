/**
 * New Space Page — form to create a new space (with its root
 * agent). The unit of creation is a space: the lobby's
 * `create_space` push creates the space + root agent in one
 * transaction.
 *
 * Features:
 * - Space name input
 * - Blueprint picker (from the lobby `init` `blueprints` payload)
 * - Model + vocation selection (root agent)
 * - Create Space button
 * - Loading state
 */

import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useStore } from "../store";
import { createSpace, rescanModels, suggestSpaceName } from "../channels";
import { vocationRequiresWorkspace } from "../utils/vocationWorkspace";

/**
 * Validate the new-space form before firing the lobby push.
 * Returns a user-facing error message or `null` when submittable.
 *
 * @param {object} params
 * @param {string} params.name — the space name input.
 * @param {string} params.selectedBlueprint — the blueprint `<select>` value.
 * @param {string} params.selectedModel — the model `<select>` value.
 * @param {boolean} params.requiresWorkspace — whether the selected
 *   blueprint's root vocation expects a workspace.
 * @param {string} params.workspacePath — the workspace path input.
 * @returns {string | null}
 */
export function validateNewSpaceForm({
  name,
  selectedBlueprint,
  selectedModel,
  requiresWorkspace,
  workspacePath,
}) {
  if (!name?.trim()) {
    return "Please enter a space name";
  }
  if (!selectedBlueprint) {
    return "Please select a blueprint";
  }
  if (!selectedModel) {
    return "Please select a model";
  }
  if (requiresWorkspace && !workspacePath?.trim()) {
    return "Please specify a workspace path";
  }
  return null;
}

/**
 * New Space Page component
 */
export function NewSpacePage() {
  const navigate = useNavigate();
  const models = useStore((s) => s.models);
  const blueprints = useStore((s) => s.blueprints);
  const vocations = useStore((s) => s.vocations);
  const suggestedName = useStore((s) => s.suggestedName);
  const [name, setName] = useState("");
  const [selectedBlueprint, setSelectedBlueprint] = useState("");
  const [selectedModel, setSelectedModel] = useState("");
  const [workspacePath, setWorkspacePath] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [isRescanning, setIsRescanning] = useState(false);
  const [error, setError] = useState(null);

  // Pre-fill the name with the backend-suggested space name from the
  // lobby `init` payload. Apply it once, only if the user hasn't typed
  // anything yet.
  const appliedSuggestionRef = useRef(false);

  useEffect(() => {
    if (suggestedName && !appliedSuggestionRef.current) {
      appliedSuggestionRef.current = true;
      setName((current) => current || suggestedName);
    }
  }, [suggestedName]);

  const selectedBlueprintData = blueprints?.find(
    (b) => b.id.toString() === selectedBlueprint,
  );
  const selectedVocation = selectedBlueprintData
    ? vocations.find((v) => v.id === selectedBlueprintData.root_vocation_id)
    : null;
  const selectedVocationName = selectedVocation?.name;
  const requiresWorkspace = vocationRequiresWorkspace(selectedVocation);

  // Reset the rescan spinner when the merged catalog lands. The
  // `rescan_models` push reply is `:ok`; the real catalog arrives
  // via the follow-up `models_updated` broadcast which replaces the
  // whole `models` array in the store.
  const lastModelsRef = useRef(models);

  useEffect(() => {
    if (lastModelsRef.current !== models && isRescanning) {
      lastModelsRef.current = models;
      setIsRescanning(false);
    }
  }, [models, isRescanning]);

  const handleRescanModels = () => {
    setIsRescanning(true);
    rescanModels(
      () => {},
      (err) => {
        setIsRescanning(false);
        setError(err?.message || "Failed to rescan providers");
      },
    );
  };

  const handleCreateSpace = () => {
    const validationError = validateNewSpaceForm({
      name,
      selectedBlueprint,
      selectedModel,
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

    createSpace(
      model,
      null,
      (resp) => {
        // The `space:created` + `agent:created` broadcasts update
        // the store; land on the new space's page. Regenerate the
        // suggestion so the next new-space form doesn't collide
        // with the name we just used.
        suggestSpaceName();
        navigate(`/space/${encodeURIComponent(resp.slug)}`);
      },
      (err) => {
        setError(err.message || "Failed to create space");
        setIsCreating(false);
      },
      {
        name: name.trim(),
        blueprint_id: parseInt(selectedBlueprint, 10),
        workspace_path: requiresWorkspace ? workspacePath.trim() : undefined,
      },
    );
  };

  return (
    <div className="max-w-2xl mx-auto py-12">
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">
          Create New Space
        </h1>
        <p className="text-gray-600 mb-8">
          A space is a container for a group of collaborating agents.
        </p>

        {/* Error message */}
        {error && (
          <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-lg">
            <p className="text-red-700">{error}</p>
          </div>
        )}

        {/* Space name */}
        <div className="mb-6">
          <label
            htmlFor="space-name"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Space Name
          </label>
          <input
            id="space-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. My Project"
            className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
            disabled={isCreating}
          />
        </div>

        {/* Blueprint selection */}
        <div className="mb-6">
          <label
            htmlFor="blueprint-select"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Select Blueprint
          </label>
          <select
            id="blueprint-select"
            value={selectedBlueprint}
            onChange={(e) => setSelectedBlueprint(e.target.value)}
            className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
            disabled={isCreating}
          >
            <option value="">Choose a blueprint...</option>
            {(blueprints || []).map((blueprint) => (
              <option key={blueprint.id} value={blueprint.id}>
                {blueprint.name}
              </option>
            ))}
          </select>
          {selectedBlueprintData && (
            <div className="mt-2 text-sm text-gray-600 space-y-1">
              {selectedVocationName && (
                <p>
                  Root agent vocation:{" "}
                  <span className="font-medium text-gray-800">
                    {selectedVocationName}
                  </span>
                </p>
              )}
              {selectedBlueprintData.description && (
                <p>{selectedBlueprintData.description}</p>
              )}
            </div>
          )}
        </div>

        {/* Model selection */}
        <div className="mb-6">
          <div className="flex items-end justify-between mb-2 gap-3">
            <label
              htmlFor="space-model-select"
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
            id="space-model-select"
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
        </div>

        {/* Workspace path input (for blueprints whose root vocation
            expects a workspace) */}
        {requiresWorkspace && (
          <div className="mb-6">
            <label
              htmlFor="space-workspace-path"
              className="block text-sm font-medium text-gray-700 mb-2"
            >
              Workspace Path
            </label>
            <input
              id="space-workspace-path"
              type="text"
              value={workspacePath}
              onChange={(e) => setWorkspacePath(e.target.value)}
              placeholder="/path/to/project"
              className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
              disabled={isCreating}
            />
            <p className="mt-2 text-sm text-gray-500">
              This blueprint's root agent needs a workspace directory to read
              and write files.
            </p>
          </div>
        )}

        {/* Create button */}
        <button
          type="button"
          onClick={handleCreateSpace}
          disabled={isCreating}
          className={`
            w-full py-3 px-4 rounded-lg font-semibold text-white
            transition-all duration-200
            ${
              isCreating
                ? "bg-gray-400 cursor-not-allowed"
                : "bg-blue-600 hover:bg-blue-700 active:bg-blue-800"
            }
          `}
        >
          {isCreating ? "Creating Space..." : "Create Space"}
        </button>
      </div>
    </div>
  );
}

export default NewSpacePage;

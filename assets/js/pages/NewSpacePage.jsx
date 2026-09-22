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
import { RescanButton } from "../components/RescanButton";
import { vocationRequiresWorkspace } from "../utils/vocationWorkspace";
import {
  resolveThinkingOptions,
  validateNewSpaceForm,
} from "../utils/newSpaceForm";

// Re-export so existing imports (`NewSpacePage.test.jsx`) keep working.
export { validateNewSpaceForm };

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
  const [selectedThinking, setSelectedThinking] = useState("medium");
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

  const thinkingOptions = resolveThinkingOptions(models, selectedModel);

  // The `rescan_models` push reply is `:ok` immediately; the real
  // work (config reload + a `/models` query per auto provider) happens
  // server-side and lands as one or more `models_updated` broadcasts.
  // Each broadcast replaces the whole `models` array with a fresh
  // identity, so clear the spinner on the first `models` change after
  // the click. `baselineModelsRef` snapshots the array at click time,
  // so a broadcast that arrived before the click (e.g. the lobby
  // `init`) doesn't clear the spinner.
  const awaitingRescanRef = useRef(false);
  const baselineModelsRef = useRef(null);

  useEffect(() => {
    if (!awaitingRescanRef.current) return;
    if (models === baselineModelsRef.current) return;

    awaitingRescanRef.current = false;
    setIsRescanning(false);
  }, [models]);

  const handleRescanModels = () => {
    awaitingRescanRef.current = true;
    baselineModelsRef.current = models;
    setIsRescanning(true);
    rescanModels(
      () => {},
      (err) => {
        awaitingRescanRef.current = false;
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

    const model = {
      ...(models.find((m) => m.name === selectedModel) || {
        name: selectedModel,
      }),
      thinking_level: selectedThinking,
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
            <RescanButton
              isRescanning={isRescanning}
              isCreating={isCreating}
              onClick={handleRescanModels}
            />
          </div>
          <select
            id="space-model-select"
            value={selectedModel}
            onChange={(e) => {
              setSelectedModel(e.target.value);
              // Reset the thinking level to the global default on a
              // model change so a stale choice isn't carried over.
              setSelectedThinking("medium");
            }}
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

        {/* Thinking level (for models that support reasoning) */}
        <div className="mb-6">
          <label
            htmlFor="space-thinking-select"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Thinking Level
          </label>
          <select
            id="space-thinking-select"
            value={selectedThinking}
            onChange={(e) => setSelectedThinking(e.target.value)}
            className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
            disabled={isCreating}
          >
            {thinkingOptions.map((level) => (
              <option key={level} value={level}>
                {level}
              </option>
            ))}
          </select>
        </div>
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

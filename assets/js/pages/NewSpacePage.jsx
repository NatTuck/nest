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
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { createSpace, rescanModels, suggestSpaceName } from "../channels";
import { RescanButton } from "../components/RescanButton";
import { describeCreateError } from "../utils/chatErrors.js";
import { vocationRequiresWorkspace } from "../utils/vocationWorkspace";
import {
  DEFAULT_SANDBOX_BACKEND,
  SANDBOX_BACKENDS,
  resolveThinkingOptions,
  sandboxBackendHelp,
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
  useDocumentTitle(["New space"]);
  const [name, setName] = useState("");
  const [selectedBlueprint, setSelectedBlueprint] = useState("");
  const [selectedModel, setSelectedModel] = useState("");
  const [selectedThinking, setSelectedThinking] = useState("medium");
  const [workspacePath, setWorkspacePath] = useState("");
  // Network access is a space property, so it is chosen here and editable later
  // on the space's own page. `null` means "the user has not chosen": the value
  // then follows the selected blueprint's `default_net`, which is what makes
  // picking a blueprint pre-fill the toggle. Once the user touches the toggle
  // their choice wins, so picking another blueprint cannot stomp it — which is
  // why this stores the *choice* rather than the value.
  const [networkChoice, setNetworkChoice] = useState(null);
  // Off by default and not derived from anything (issue #176): the notices can
  // read as "stop now", so a space opts in, here or later in the edit dialog.
  const [contextWarnings, setContextWarnings] = useState(false);
  const [sandboxBackend, setSandboxBackend] = useState(DEFAULT_SANDBOX_BACKEND);
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
    ? vocations.find((v) => v.slug === selectedBlueprintData.root_vocation)
    : null;
  const selectedVocationName = selectedVocation?.name;
  const requiresWorkspace = vocationRequiresWorkspace(selectedVocation);

  // The blueprint's `default_net` is a *default*, not a policy: `??` rather than
  // `||`, so a blueprint that says `false` is honoured, and `true` when nothing
  // says otherwise — which is what a space got before blueprints had a
  // `default_net` at all (and what a form with no blueprint selected gets).
  const networkAccess =
    networkChoice ?? selectedBlueprintData?.default_net ?? true;

  const thinkingOptions = resolveThinkingOptions(models, selectedModel);

  // The server holds the `rescan_models` push open until the scan is
  // genuinely complete (every auto-provider answered, or its deadline
  // fired) and only then replies. Per-provider `models_updated`
  // partials are NOT completion and must never clear the spinner.
  const handleRescanModels = () => {
    setIsRescanning(true);
    setError(null);
    rescanModels(
      () => {
        setIsRescanning(false);
      },
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
      sandboxBackend,
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
        setError(describeCreateError(err));
        setIsCreating(false);
      },
      {
        name: name.trim(),
        blueprint_id: parseInt(selectedBlueprint, 10),
        workspace_path: requiresWorkspace ? workspacePath.trim() : undefined,
        sandbox_backend: sandboxBackend,
        network_access: networkAccess,
        context_warnings: contextWarnings,
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

        {/* Sandbox backend (chosen once at creation, immutable after) */}
        <div className="mb-6">
          <label
            htmlFor="space-sandbox-backend"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Sandbox
          </label>
          <select
            id="space-sandbox-backend"
            value={sandboxBackend}
            onChange={(e) => setSandboxBackend(e.target.value)}
            className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all"
            disabled={isCreating}
          >
            {SANDBOX_BACKENDS.map((backend) => (
              <option key={backend} value={backend}>
                {backend}
              </option>
            ))}
          </select>
          <p className="mt-2 text-sm text-gray-500">
            {sandboxBackendHelp(sandboxBackend)}
          </p>
        </div>

        {/* Network access (a space property, editable later) */}
        <div className="mb-6 flex items-start gap-3">
          <input
            id="space-network-access"
            type="checkbox"
            checked={networkAccess}
            onChange={(e) => setNetworkChoice(e.target.checked)}
            disabled={isCreating}
            className="mt-0.5 h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 disabled:opacity-50"
          />
          <div>
            <label
              htmlFor="space-network-access"
              className="text-sm font-medium text-gray-700"
            >
              Network access
            </label>
            <p className="text-sm text-gray-500">
              Whether this space's agents may reach the network. Starts from the
              selected blueprint's choice; a space with no sandbox cannot
              enforce this.
            </p>
          </div>
        </div>

        {/* Context warnings (a space property, off by default) */}
        <div className="mb-6 flex items-start gap-3">
          <input
            id="space-context-warnings"
            type="checkbox"
            checked={contextWarnings}
            onChange={(e) => setContextWarnings(e.target.checked)}
            disabled={isCreating}
            className="mt-0.5 h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 disabled:opacity-50"
          />
          <div>
            <label
              htmlFor="space-context-warnings"
              className="text-sm font-medium text-gray-700"
            >
              Context warnings
            </label>
            <p className="text-sm text-gray-500">
              Whether the runtime tells this space's agents when their context
              is 25%, 50% or 75% full. Off by default: a warning can read as
              "stop now". Editable later on the space's own page.
            </p>
          </div>
        </div>

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

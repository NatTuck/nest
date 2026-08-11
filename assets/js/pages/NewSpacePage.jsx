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

import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useStore } from "../store";
import { createSpace } from "../channels";

/**
 * Validate the new-space form before firing the lobby push.
 * Returns a user-facing error message or `null` when submittable.
 *
 * @param {object} params
 * @param {string} params.name — the space name input.
 * @param {string} params.selectedBlueprint — the blueprint `<select>` value.
 * @param {string} params.selectedModel — the model `<select>` value.
 * @returns {string | null}
 */
export function validateNewSpaceForm({
  name,
  selectedBlueprint,
  selectedModel,
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
  return null;
}

/**
 * New Space Page component
 */
export function NewSpacePage() {
  const navigate = useNavigate();
  const models = useStore((s) => s.models);
  const blueprints = useStore((s) => s.blueprints);
  const [name, setName] = useState("");
  const [selectedBlueprint, setSelectedBlueprint] = useState("");
  const [selectedModel, setSelectedModel] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState(null);

  const selectedBlueprintData = blueprints?.find(
    (b) => b.id.toString() === selectedBlueprint,
  );

  const handleCreateSpace = () => {
    const validationError = validateNewSpaceForm({
      name,
      selectedBlueprint,
      selectedModel,
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
      () => {
        // The `space:created` + `agent:created` broadcasts update
        // the store; land on the spaces index.
        navigate("/spaces");
      },
      (err) => {
        setError(err.message || "Failed to create space");
        setIsCreating(false);
      },
      {
        name: name.trim(),
        blueprint_id: parseInt(selectedBlueprint, 10),
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
            <p className="mt-2 text-sm text-gray-600">
              {selectedBlueprintData.description}
            </p>
          )}
        </div>

        {/* Model selection */}
        <div className="mb-6">
          <label
            htmlFor="space-model-select"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Select Model
          </label>
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

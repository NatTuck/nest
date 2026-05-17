/**
 * New Agent Page - Form to create a new agent.
 *
 * Features:
 * - Model selection dropdown
 * - Create Agent button
 * - Loading state
 * - Navigate to new agent on success
 */

import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useStore } from "../store";
import { createAgent } from "../channels";

/**
 * New Agent Page component
 */
export function NewAgentPage() {
  const navigate = useNavigate();
  const { models } = useStore();
  const [selectedModel, setSelectedModel] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState(null);

  const handleCreateAgent = () => {
    if (!selectedModel) {
      setError("Please select a model");
      return;
    }

    setIsCreating(true);
    setError(null);

    const model = models.find((m) => m.name === selectedModel) || {
      name: selectedModel,
    };
    createAgent(
      model,
      (id) => {
        navigate(`/agent/${id}`);
      },
      (err) => {
        setError(err.message || "Failed to create agent");
        setIsCreating(false);
      }
    );
  };

  return (
    <div className="max-w-2xl mx-auto py-12">
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">
          Create New Agent
        </h1>
        <p className="text-gray-600 mb-8">
          Select a model and spawn a new AI agent to chat with.
        </p>

        {/* Error message */}
        {error && (
          <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-lg">
            <p className="text-red-700">{error}</p>
          </div>
        )}

        {/* Model selection */}
        <div className="mb-6">
          <label
            htmlFor="model-select"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Select Model
          </label>
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
          disabled={isCreating || !selectedModel}
          className={`
            w-full py-3 px-4 rounded-lg font-semibold text-white
            transition-all duration-200
            ${
              isCreating || !selectedModel
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
            What is an Agent?
          </h3>
          <p className="text-sm text-gray-600">
            An agent is an AI assistant powered by a language model. Each agent
            maintains its own conversation history and can be customized with
            different models. Agents run independently and persist until you
            delete them.
          </p>
        </div>
      </div>
    </div>
  );
}

export default NewAgentPage;

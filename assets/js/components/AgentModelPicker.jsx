/**
 * AgentModelPicker — Modal for picking a replacement model.
 *
 * Used by:
 *   - ChatPage header chip (always available for editing the
 *     active agent's model)
 *   - ChatPage prominent :model_missing banner (the only way to
 *     recover a broken agent — see
 *     `lib/nest/agents/agent/init/recovery.ex`)
 *
 * Reads the model catalog from the zustand store (seeded by
 * the lobby's `init` payload) and forwards the user's selection
 * via the supplied `onSelect(modelMap)` callback. The parent
 * decides whether to push `"change_model"` over the agent
 * channel or the lobby channel.
 *
 * About thinking-block loss when switching across providers:
 *
 *   Switching the agent's model mid-conversation is safe across
 *   providers (OpenAI ↔ Anthropic). The wire format is wire-
 *   agnostic at the canonical-message layer. The only semantic
 *   loss is Anthropic `Thinking` parts being silently dropped
 *   from the OpenAI wire (`text_from_parts/1` filters to
 *   `%Part.Text{}` only). We surface that caveat inline below
 *   the catalog so the user makes an informed choice.
 */

import { useState } from "react";
import { useStore } from "../store";

export function AgentModelPicker({ open, onClose, onSelect }) {
  const models = useStore((state) => state.models);
  const [selectedName, setSelectedName] = useState("");
  const [searchTerm, setSearchTerm] = useState("");

  if (!open) {
    return null;
  }

  const filteredModels = models.filter((model) =>
    model.name.toLowerCase().includes(searchTerm.toLowerCase()),
  );

  const handleSelect = (model) => {
    onSelect({ name: model.name, provider: model.provider });
    setSelectedName(model.name);
    setSearchTerm("");
  };

  const handleKeyDown = (e) => {
    if (e.key === "Escape") {
      onClose();
    }
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Pick a model"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
      onKeyDown={handleKeyDown}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Pick a model</h2>
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
        <div className="px-6 pt-4">
          <input
            type="search"
            placeholder="Filter models…"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
          />
        </div>
        <div className="px-2 py-3 max-h-72 overflow-y-auto">
          {filteredModels.length === 0 ? (
            <p className="text-center text-sm text-gray-500 py-6">
              No models match the filter.
            </p>
          ) : (
            <div className="divide-y divide-gray-100">
              {filteredModels.map((model) => {
                const isSelected = model.name === selectedName;
                return (
                  <div key={model.name}>
                    <button
                      type="button"
                      onClick={() => handleSelect(model)}
                      className={`
                        w-full text-left px-4 py-3 rounded-lg
                        flex items-center justify-between gap-3
                        transition-colors duration-150
                        ${
                          isSelected
                            ? "bg-blue-50 ring-1 ring-blue-200"
                            : "hover:bg-gray-50"
                        }
                      `}
                    >
                      <span className="flex flex-col min-w-0">
                        <span className="font-mono text-sm text-gray-900 truncate">
                          {model.name}
                        </span>
                        {model.provider && (
                          <span className="text-xs text-gray-500 truncate">
                            {model.provider}
                          </span>
                        )}
                      </span>
                      {isSelected && (
                        <span className="text-xs font-medium text-blue-600 flex-shrink-0">
                          Selected
                        </span>
                      )}
                    </button>
                  </div>
                );
              })}
            </div>
          )}
        </div>
        <div className="px-6 py-4 border-t border-gray-200 bg-gray-50">
          <p className="text-xs text-gray-500">
            Switching providers may silently drop prior <em>thinking</em> blocks
            from the conversation (the wire format preserves text + tool history
            but not thinking signatures).{" "}
            <a
              href="https://github.com/anomalyco/opencode#model-switching"
              className="text-blue-600 hover:underline"
              target="_blank"
              rel="noopener noreferrer"
            >
              Learn more
            </a>
            .
          </p>
        </div>
      </div>
    </div>
  );
}

/**
 * A single editable model row within a provider editor: name, context
 * limit, and thinking effort. `multi_modal` is preserved but not edited.
 */

import { THINKING_LEVELS } from "./providerConstants";

export function ProviderModelRow({ model, onChange, onRemove }) {
  const set = (field, value) => onChange({ ...model, [field]: value });

  return (
    <div className="flex items-center gap-2 bg-gray-50 rounded-md px-2 py-1.5 border border-gray-200">
      <input
        type="text"
        value={model.name ?? ""}
        onChange={(e) => set("name", e.target.value)}
        placeholder="model name"
        aria-label="Model name"
        className="flex-1 min-w-0 px-2 py-1 text-sm border border-gray-300 rounded-md outline-none focus:ring-2 focus:ring-blue-500"
      />
      <input
        type="number"
        value={model.context_limit ?? ""}
        onChange={(e) =>
          set("context_limit", e.target.value ? Number(e.target.value) : null)
        }
        placeholder="context-limit"
        aria-label="Model context limit"
        className="w-28 px-2 py-1 text-sm border border-gray-300 rounded-md outline-none focus:ring-2 focus:ring-blue-500"
      />
      <select
        value={model.thinking_effort ?? ""}
        onChange={(e) => set("thinking_effort", e.target.value || null)}
        aria-label="Model thinking effort"
        className="px-2 py-1 text-sm border border-gray-300 rounded-md outline-none focus:ring-2 focus:ring-blue-500"
      >
        <option value="">default</option>
        {THINKING_LEVELS.map((l) => (
          <option key={l} value={l}>
            {l}
          </option>
        ))}
      </select>
      <button
        type="button"
        onClick={onRemove}
        aria-label={`Remove model ${model.name ?? ""}`}
        className="p-1 text-gray-400 hover:text-red-600 transition-colors"
      >
        <svg
          className="w-4 h-4"
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
  );
}

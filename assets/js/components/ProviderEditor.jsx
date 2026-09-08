/**
 * An editable provider card for the Providers admin screen: connection
 * settings, an "Auto-discover models" toggle, and the provider's
 * configured models (add/edit/remove). Changes are reported upward via
 * `onChange`; the page owns the list and the Save action.
 */

import { emptyModel, PROTOCOLS, THINKING_LEVELS } from "./providerConstants";
import { ProviderModelRow } from "./ProviderModelRow";

function Field({ label, children }) {
  return (
    <div className="flex flex-col gap-1 text-xs font-medium text-gray-600">
      <span>{label}</span>
      {children}
    </div>
  );
}

const inputCls =
  "px-2 py-1 text-sm border border-gray-300 rounded-md outline-none focus:ring-2 focus:ring-blue-500";

export function ProviderEditor({ provider, onChange, onRemove }) {
  const set = (field, value) => onChange({ ...provider, [field]: value });

  const setModel = (idx, model) =>
    set(
      "models",
      provider.models.map((m, i) => (i === idx ? model : m)),
    );

  const removeModel = (idx) =>
    set(
      "models",
      provider.models.filter((_, i) => i !== idx),
    );
  const addModel = () =>
    set("models", [...(provider.models || []), emptyModel()]);

  return (
    <div className="border border-gray-200 rounded-lg p-4 space-y-3 bg-white">
      <div className="flex items-center justify-between gap-2">
        <input
          type="text"
          value={provider.name ?? ""}
          onChange={(e) => set("name", e.target.value)}
          placeholder="provider name"
          aria-label="Provider name"
          className={`${inputCls} font-medium flex-1`}
        />
        <button
          type="button"
          onClick={onRemove}
          aria-label={`Delete provider ${provider.name ?? ""}`}
          className="p-1.5 text-gray-400 hover:text-red-600 transition-colors"
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
              d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
            />
          </svg>
        </button>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Field label="Base URL">
          <input
            type="text"
            value={provider.base_url ?? ""}
            onChange={(e) => set("base_url", e.target.value)}
            className={inputCls}
            aria-label="Base URL"
          />
        </Field>
        <Field label="API Key">
          <input
            type="password"
            value={provider.api_key ?? ""}
            onChange={(e) => set("api_key", e.target.value)}
            className={inputCls}
            aria-label="API key"
          />
        </Field>
        <Field label="Protocol">
          <select
            value={provider.protocol ?? "openai"}
            onChange={(e) => set("protocol", e.target.value)}
            className={inputCls}
            aria-label="Protocol"
          >
            {PROTOCOLS.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Default Context Limit">
          <input
            type="number"
            value={provider.default_context_limit ?? ""}
            onChange={(e) =>
              set(
                "default_context_limit",
                e.target.value ? Number(e.target.value) : null,
              )
            }
            className={inputCls}
            aria-label="Default context limit"
          />
        </Field>
        <Field label="Default Thinking Effort">
          <select
            value={provider.default_thinking_effort ?? ""}
            onChange={(e) =>
              set("default_thinking_effort", e.target.value || null)
            }
            className={inputCls}
            aria-label="Default thinking effort"
          >
            <option value="">default</option>
            {THINKING_LEVELS.map((l) => (
              <option key={l} value={l}>
                {l}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Probe Base URL (discovery)">
          <input
            type="text"
            value={provider.probe_base_url ?? ""}
            onChange={(e) => set("probe_base_url", e.target.value || null)}
            className={inputCls}
            aria-label="Probe base URL"
          />
        </Field>
      </div>

      <div className="flex items-center gap-6 text-sm text-gray-700">
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={!!provider.auto_models}
            onChange={(e) => set("auto_models", e.target.checked)}
            aria-label="Auto-discover models"
          />
          Auto-discover models
        </label>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={provider.auto_probe !== false}
            onChange={(e) => set("auto_probe", e.target.checked)}
            aria-label="Auto-probe endpoint"
          />
          Auto-probe endpoint
        </label>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={!!provider.expose_models}
            onChange={(e) => set("expose_models", e.target.checked)}
            aria-label="Expose models in list-models"
          />
          Expose models in list-models
        </label>
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <p className="text-xs font-semibold text-gray-600 uppercase tracking-wider">
            Models
          </p>
          <button
            type="button"
            onClick={addModel}
            aria-label="Add model"
            className="px-2 py-0.5 text-xs font-medium text-blue-600 border border-blue-300 rounded-md hover:bg-blue-50 transition-colors"
          >
            + Add model
          </button>
        </div>
        {(provider.models || []).map((model, idx) => (
          <ProviderModelRow
            key={model.id ?? idx}
            model={model}
            onChange={(m) => setModel(idx, m)}
            onRemove={() => removeModel(idx)}
          />
        ))}
        {(provider.models || []).length === 0 && (
          <p className="text-xs text-gray-400">No models configured.</p>
        )}
      </div>
    </div>
  );
}

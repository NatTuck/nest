/**
 * Providers admin screen (admin-only). Lists the configured LLM
 * providers and their models, lets the user add/edit/delete them, and
 * a Save button persists the full set to `~/.config/nest/local.toml`
 * (never `config.toml`). Setting a provider's "Auto-discover models"
 * flag lets the runtime discover its models from the `/models` endpoint.
 */

import { useEffect, useState } from "react";
import { Navigate } from "react-router-dom";
import { useStore } from "../store";
import { saveProviders } from "../channels";
import { ProviderEditor } from "../components/ProviderEditor";
import { emptyProvider, makeId } from "../components/providerConstants";

export function ProvidersPage() {
  const providers = useStore((state) => state.providers);
  const isAdmin = useStore((state) => state.currentUser?.is_admin);

  // Seed the editable draft immediately so the first render already
  // carries stable ids (the effect below keeps it in sync with the
  // store's provider list). Store-seeded providers/models come back
  // without ids.
  const [draft, setDraft] = useState(() => assignIds(providers));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  // Re-seed the editable draft whenever the store's provider list
  // changes (initial lobby `init`, or a `providers_updated` broadcast
  // after a successful save elsewhere). Store-seeded providers/models
  // get a stable client-side `id` used purely as a React key so that
  // editing a name doesn't remount the editor and drop focus. The ids
  // persist across edits because this effect only re-runs when the
  // store's `providers` reference changes.
  useEffect(() => {
    setDraft(assignIds(providers));
  }, [providers]);

  if (!isAdmin) {
    return <Navigate to="/spaces" replace />;
  }

  const updateProvider = (idx, provider) =>
    setDraft(draft.map((p, i) => (i === idx ? provider : p)));

  const removeProvider = (idx) => setDraft(draft.filter((_, i) => i !== idx));
  const addProvider = () => setDraft([...draft, emptyProvider()]);

  const handleSave = () => {
    setSaving(true);
    setError(null);

    saveProviders(
      stripIds(draft),
      () => setSaving(false),
      (err) => {
        setError(err?.reason || "Failed to save provider config");
        setSaving(false);
      },
    );
  };

  return (
    <div className="max-w-3xl mx-auto py-12">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900 mb-1">Providers</h1>
        <p className="text-sm text-gray-600">
          Configure LLM providers and their models. Saving writes to{" "}
          <code className="text-gray-800">~/.config/nest/local.toml</code> and
          leaves <code className="text-gray-800">config.toml</code> untouched.
        </p>
      </div>

      {error && (
        <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-lg">
          <p className="text-red-700 text-sm">{error}</p>
        </div>
      )}

      <div className="space-y-4">
        {draft.map((provider, idx) => (
          <ProviderEditor
            key={provider.id}
            provider={provider}
            onChange={(p) => updateProvider(idx, p)}
            onRemove={() => removeProvider(idx)}
          />
        ))}

        {draft.length === 0 && (
          <p className="text-sm text-gray-400 text-center py-8">
            No providers configured. Add one below.
          </p>
        )}
      </div>

      <div className="mt-6 flex items-center justify-between gap-3">
        <button
          type="button"
          onClick={addProvider}
          disabled={saving}
          className="px-4 py-2 rounded-lg text-sm font-medium text-blue-700 border border-blue-300 hover:bg-blue-50 transition-colors"
        >
          + Add provider
        </button>
        <button
          type="button"
          onClick={handleSave}
          disabled={saving}
          className="px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors disabled:opacity-50"
        >
          {saving ? "Saving..." : "Save"}
        </button>
      </div>
    </div>
  );
}

// Assign a stable client-side `id` to any provider/model that doesn't
// already have one (store-seeded providers come back without ids).
// Used purely as a React key so name edits don't remount editors.
function assignIds(providers) {
  return providers.map((provider) => ({
    ...provider,
    id: provider.id ?? makeId(),
    models: (provider.models || []).map((model) => ({
      ...model,
      id: model.id ?? makeId(),
    })),
  }));
}

// Drop the client-only `id` fields before sending the draft to the
// server — they're React-key bookkeeping, not provider config.
function stripIds(providers) {
  return providers.map((provider) => {
    const { id: _providerId, models, ...rest } = provider;
    return {
      ...rest,
      models: (models || []).map(({ id: _modelId, ...model }) => model),
    };
  });
}

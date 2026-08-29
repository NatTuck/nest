/**
 * The `:model_missing` repair banner — shown when the agent's persisted
 * model no longer resolves to a runtime provider. The user picks a
 * replacement model to recover. Extracted from `ChatPage`.
 */

export function ModelMissingBanner({ model, onChooseModel }) {
  return (
    <div
      role="alert"
      aria-live="polite"
      className="bg-amber-50 border-l-4 border-amber-500 p-4 mb-4"
    >
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-amber-900 font-medium">
            Model{" "}
            <span className="font-mono">{model?.name ?? "(unknown)"}</span> is
            no longer available
          </p>
          <p className="text-amber-800 text-sm mt-1">
            Your conversation history is preserved. Pick a replacement model to
            continue — the agent resumes in{" "}
            <span className="font-mono">idle</span> the moment the new model is
            set.
          </p>
        </div>
        <button
          type="button"
          onClick={onChooseModel}
          className="flex-shrink-0 px-4 py-2 rounded-lg font-medium text-amber-900 bg-amber-200 hover:bg-amber-300 active:bg-amber-400 transition-colors"
        >
          Choose replacement model
        </button>
      </div>
    </div>
  );
}

/**
 * SpawnAgentDialog — the manual "spawn an agent in this space" form (#209).
 *
 * It creates a **top-level** agent: a peer of the space's root, not a child of
 * anything in the tree. That is what makes it a space-level action rather than
 * something an agent asks for, and it is why the control lives on the space's
 * own page.
 *
 * The form is deliberately three fields — name, vocation, model — because the
 * rest of an agent's identity comes from the space it is in (its workspace, its
 * sandbox, its network) and from its vocation (its system prompt and tools).
 * Nothing here invents a default for the *name*: a blank name is left out of the
 * payload, which is what tells the server to generate one.
 *
 * Nothing is added to the store when the push succeeds. The server broadcasts
 * `agent_created` and `channels.js` applies it, so the tree is the server's
 * statement rather than this dialog's guess; a spawn that the server refused
 * half-way cannot leave a phantom row behind.
 */

import { useEffect, useState } from "react";

import { spawnAgent } from "../channels";
import { useStore } from "../store";

/**
 * The thinking level sent with a chosen model. The form has no thinking control
 * (#209 asks for three fields), so this is the application's default rather than
 * a choice — the same `"medium"` the new-space form starts at.
 */
const DEFAULT_THINKING_LEVEL = "medium";

export function SpawnAgentDialog({
  open,
  onClose,
  spaceId,
  blueprint,
  onSpawned,
}) {
  const vocations = useStore((state) => state.vocations) ?? [];
  const models = useStore((state) => state.models) ?? [];

  const [name, setName] = useState("");
  const [vocation, setVocation] = useState("");
  const [modelName, setModelName] = useState("");
  const [error, setError] = useState(null);
  const [spawning, setSpawning] = useState(false);

  // Each opening starts from a clean form: the previous spawn's name, error and
  // in-flight flag are not this one's. Keyed on `open` alone — a lobby frame that
  // replaces `vocations` or `blueprints` while the form is open must not wipe what
  // the operator has typed.
  useEffect(() => {
    if (!open) return;
    setName("");
    setVocation("");
    setModelName("");
    setError(null);
    setSpawning(false);
  }, [open]);

  if (!open) {
    return null;
  }

  // The vocation's default is derived, not stored: a space spawned by hand is
  // almost always the same kind of agent as its root, so the blueprint's root
  // vocation is what the select shows until the operator picks another — and it
  // is what gets sent, because the server is told what the select displays. An
  // empty store (the lobby's `init` has not landed) falls back to nothing, and
  // then the payload omits the field rather than inventing one.
  const chosenVocation =
    vocation || blueprint?.root_vocation || vocations[0]?.slug || "";

  const submit = () => {
    // No double submit: the push is in flight and the reply is what closes the
    // dialog, so a second click would spawn a second agent.
    if (spawning) return;

    const chosenModel = models.find((model) => model.name === modelName);
    const payload = {
      space_id: spaceId,
      // Omitted, not empty: a blank name means "generate one".
      ...(name.trim() ? { name: name.trim() } : {}),
      ...(chosenVocation ? { vocation: chosenVocation } : {}),
      // Omitted when nothing is chosen: the server's default model.
      ...(chosenModel
        ? {
            model: {
              name: chosenModel.name,
              provider: chosenModel.provider ?? null,
              thinking_level: DEFAULT_THINKING_LEVEL,
            },
          }
        : {}),
    };

    setSpawning(true);
    setError(null);

    spawnAgent(
      payload,
      (reply) => {
        setSpawning(false);
        if (onSpawned) onSpawned(reply?.name ?? null);
        onClose();
      },
      (err) => {
        setSpawning(false);
        // The reply's own words first (`message`, then `reason`), and the
        // "not connected" guard's `Error` has a `message` too.
        setError(err?.message || err?.reason || "Failed to spawn the agent");
      },
    );
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Spawn agent"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
      onKeyDown={(event) => {
        if (event.key === "Escape" && !spawning) onClose();
      }}
      onClick={(event) => {
        if (event.target === event.currentTarget && !spawning) onClose();
      }}
    >
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 overflow-hidden flex max-h-[90dvh] flex-col">
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Spawn agent</h2>
          <button
            type="button"
            onClick={onClose}
            disabled={spawning}
            aria-label="Close"
            className="text-gray-400 hover:text-gray-600 transition-colors p-1 disabled:opacity-50"
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

        <div className="px-6 py-4 space-y-4 min-h-0 flex-1 overflow-y-auto">
          <p className="text-sm text-gray-600">
            A new top-level agent in this space, alongside its root.
          </p>

          <div>
            <label
              htmlFor="spawn-name"
              className="block text-sm font-medium text-gray-700 mb-1"
            >
              Name <span className="font-normal text-gray-500">(optional)</span>
            </label>
            <input
              id="spawn-name"
              type="text"
              value={name}
              onChange={(event) => setName(event.target.value)}
              placeholder="Leave blank to generate one"
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
            />
          </div>

          <div>
            <label
              htmlFor="spawn-vocation"
              className="block text-sm font-medium text-gray-700 mb-1"
            >
              Vocation
            </label>
            <select
              id="spawn-vocation"
              value={chosenVocation}
              onChange={(event) => setVocation(event.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
            >
              {vocations.length === 0 && (
                <option value="">No vocations available</option>
              )}
              {vocations.map((held) => (
                <option key={held.slug} value={held.slug}>
                  {held.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label
              htmlFor="spawn-model"
              className="block text-sm font-medium text-gray-700 mb-1"
            >
              Model
            </label>
            <select
              id="spawn-model"
              value={modelName}
              onChange={(event) => setModelName(event.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm"
            >
              {/* Empty is a real choice here: it means "the server's default",
                  which is why the payload omits `model` rather than sending a
                  half-filled map. */}
              <option value="">Choose a model… (default)</option>
              {models.map((model) => (
                <option key={model.name} value={model.name}>
                  {model.name}
                  {model.provider ? ` (${model.provider})` : ""}
                </option>
              ))}
            </select>
          </div>

          {error && (
            <p className="text-sm text-red-600" role="alert">
              {error}
            </p>
          )}
        </div>

        <div className="px-6 py-4 border-t border-gray-200 bg-gray-50 flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            disabled={spawning}
            className="px-4 py-2 rounded-lg text-sm font-medium text-gray-600 hover:bg-gray-100 transition-colors disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={spawning}
            className="px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors disabled:opacity-50"
          >
            {spawning ? "Spawning…" : "Spawn"}
          </button>
        </div>
      </div>
    </div>
  );
}

export default SpawnAgentDialog;

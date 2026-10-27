/**
 * EditSpaceDialog — modal form for a space's **environment**: the workspace it
 * binds, whether its agents may reach the network, and which sandbox backend
 * runs them — plus whether the runtime's context-usage notices are on.
 *
 * One dialog for the three environment properties because they are one
 * decision: every agent in the space inherits them, and a save tells the live
 * ones (`Agent.space_changed/2`) rather than restarting anything. The
 * consequence sentence is not decoration — all three are part of the
 * container's identity, so *any* change releases it and everything that lived
 * only there goes with it — and it is stated before the save, not after. A save
 * that changes nothing releases nothing (the server skips it), which is why the
 * sentence says "a change".
 *
 * The context-warnings toggle is the exception the help text spells out: it is
 * not part of the container, so a save stops and releases nothing, and each
 * agent picks the value up as it starts.
 *
 * The per-backend help text is the New Space form's (`sandboxBackendHelp/1`),
 * reused rather than restated: the two forms offer the same three backends and
 * must not describe them differently.
 *
 * Used by: `SpaceView` (the space's own page).
 *
 * Props:
 *   - `open`    — show/hide the modal.
 *   - `onClose` — close the modal (Escape / backdrop / X, and after a save).
 *   - `space`   — the space being edited; its `workspace_path`,
 *                 `network_access`, `sandbox_backend` and `context_warnings`
 *                 initialize the form.
 */

import { useEffect, useRef, useState } from "react";
import { cancelEditSpace, editSpace } from "../channels";
import { describeSpaceEditError } from "../utils/chatErrors.js";
import {
  DEFAULT_SANDBOX_BACKEND,
  SANDBOX_BACKENDS,
  sandboxBackendHelp,
} from "../utils/newSpaceForm";

/**
 * What a save does, in the user's terms. Exported so the test pins the wording
 * rather than a substring of the markup.
 */
export const EDIT_SPACE_CONSEQUENCE =
  "Saving restarts nothing, but every agent here is told. A change to a docker space releases its container, so /tmp offloads, background-job logs and any running background job are lost.";

/**
 * What a save does *when it has to stop something*, in the user's terms. The
 * server answers the first push with `confirmation_required` and the plan it
 * carries; this is the sentence above that list.
 */
export const EDIT_SPACE_STOPS_WORK =
  "This space is being edited, so nothing new starts in it until you decide. Continuing stops the work below: the tool calls in flight are cancelled and report an error to their agent, background shell jobs are stopped, and the environment change is applied. Cancelling costs nothing — everything simply carries on.";

export function EditSpaceDialog({ open, onClose, space }) {
  const [workspacePath, setWorkspacePath] = useState("");
  const [networkAccess, setNetworkAccess] = useState(true);
  const [contextWarnings, setContextWarnings] = useState(false);
  const [sandboxBackend, setSandboxBackend] = useState(DEFAULT_SANDBOX_BACKEND);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  // The plan the server returned instead of saving: `{agents, jobs}`. Non-null
  // means the space's latch is up on our behalf and the user has to decide.
  const [confirmPlan, setConfirmPlan] = useState(null);

  // The latest row, so the seed below can read its values without *depending* on
  // them: the store replaces a space's whole object on every `space:updated`
  // frame (another session's edit, or a rejoin's `init`), and re-seeding on that
  // would throw away whatever the user had typed. Declared before the seed
  // effect so it has run by the time that one reads it.
  const latest = useRef(space);
  useEffect(() => {
    latest.current = space;
  });

  const spaceId = space?.id ?? null;

  // Initialize the form when the modal opens, and again only when it is opened
  // for a *different* space.
  useEffect(() => {
    if (!open || spaceId === null) return;

    const row = latest.current;
    setWorkspacePath(row?.workspace_path ?? "");
    setNetworkAccess(row?.network_access === true);
    setContextWarnings(row?.context_warnings === true);
    setSandboxBackend(row?.sandbox_backend ?? DEFAULT_SANDBOX_BACKEND);
    setSaving(false);
    setSaveError(null);
    setConfirmPlan(null);
  }, [open, spaceId]);

  // The dialog is a modal, so the keyboard (Escape included) has to reach it
  // without a click first. `autoFocus` is the obvious way and the linter is
  // right to refuse it; focusing the first field here is the same effect without
  // stealing focus from a page that never opened the dialog.
  const workspaceRef = useRef(null);
  useEffect(() => {
    if (open) workspaceRef.current?.focus();
  }, [open]);

  if (!open) {
    return null;
  }

  // The page only opens this for a space it found, so a missing one is a bug in
  // the caller. Say so rather than rendering an empty form: an empty form would
  // look like a space with no workspace, and saving it would be a real edit.
  if (!space) {
    return (
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Edit space"
        className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
      >
        <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 p-6">
          <p className="text-sm text-red-600" role="alert">
            This dialog was opened without a space. That is a bug in the page,
            not something you can fix here.
          </p>
        </div>
      </div>
    );
  }

  // Closing while the space is paused releases it: the latch the preview took is
  // what stops anything starting in the space, and the server holds it until this
  // session says no (or its claim expires). Sent unconditionally rather than only
  // when the plan is on screen: the reply that carries the plan can arrive after
  // the close, and a claim taken by that in-flight push has no other way down
  // before its TTL. The release is owner-scoped server-side, so a dialog that
  // never held anything is a no-op.
  const handleClose = () => {
    cancelEditSpace(space.id);
    setConfirmPlan(null);
    setSaving(false);
    onClose();
  };

  const save = (confirm) => {
    const workspace = workspacePath.trim();
    if (!workspace) {
      setSaveError("Please enter a workspace path.");
      return;
    }

    setSaving(true);
    setSaveError(null);

    const values = {
      workspace_path: workspace,
      network_access: networkAccess,
      sandbox_backend: sandboxBackend,
      context_warnings: contextWarnings,
    };

    // Only the confirmation carries the flag; the first push is the one the
    // server may answer with `confirmation_required`.
    if (confirm) values.confirm = true;

    editSpace(
      space.id,
      values,
      () => {
        setSaving(false);
        setConfirmPlan(null);
        onClose();
      },
      (err) => {
        setSaving(false);

        // Not a refusal: the edit would stop work, and the server wants the
        // user's word. It is holding the space paused while it asks.
        if (err?.reason === "confirmation_required") {
          setConfirmPlan({ agents: err.agents ?? [], jobs: err.jobs ?? 0 });
          return;
        }

        setSaveError(describeSpaceEditError(err));
      },
    );
  };

  const handleKeyDown = (e) => {
    if (e.key === "Escape") handleClose();
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Edit space"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
      onKeyDown={handleKeyDown}
      onClick={(e) => {
        if (e.target === e.currentTarget) handleClose();
      }}
    >
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Edit space</h2>
          <button
            type="button"
            onClick={handleClose}
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

        <div className="px-6 py-4 space-y-4">
          {confirmPlan ? (
            <ConfirmStop plan={confirmPlan} error={saveError} />
          ) : (
            <>
              <div>
                <label
                  htmlFor="edit-space-workspace-path"
                  className="block text-sm font-medium text-gray-700 mb-1"
                >
                  Workspace Path
                </label>
                <input
                  id="edit-space-workspace-path"
                  type="text"
                  ref={workspaceRef}
                  value={workspacePath}
                  onChange={(e) => setWorkspacePath(e.target.value)}
                  placeholder="/path/to/project"
                  disabled={saving}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm disabled:opacity-50"
                />
                <p className="mt-1 text-sm text-gray-500">
                  Every agent in this space binds this directory.
                </p>
              </div>

              <div className="flex items-start gap-3">
                <input
                  id="edit-space-network-access"
                  type="checkbox"
                  checked={networkAccess}
                  onChange={(e) => setNetworkAccess(e.target.checked)}
                  disabled={saving}
                  className="mt-0.5 h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 disabled:opacity-50"
                />
                <div>
                  <label
                    htmlFor="edit-space-network-access"
                    className="text-sm font-medium text-gray-700"
                  >
                    Network access
                  </label>
                  <p className="text-sm text-gray-500">
                    Whether this space's agents may reach the network. A space
                    with no sandbox cannot enforce this.
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-3">
                <input
                  id="edit-space-context-warnings"
                  type="checkbox"
                  checked={contextWarnings}
                  onChange={(e) => setContextWarnings(e.target.checked)}
                  disabled={saving}
                  className="mt-0.5 h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 disabled:opacity-50"
                />
                <div>
                  <label
                    htmlFor="edit-space-context-warnings"
                    className="text-sm font-medium text-gray-700"
                  >
                    Context warnings
                  </label>
                  <p className="text-sm text-gray-500">
                    Whether the runtime tells these agents when their context is
                    25%, 50% or 75% full. Off by default: a warning can read as
                    "stop now". Nothing is stopped or released by this, and each
                    agent picks it up as it starts.
                  </p>
                </div>
              </div>

              <div>
                <label
                  htmlFor="edit-space-sandbox-backend"
                  className="block text-sm font-medium text-gray-700 mb-1"
                >
                  Sandbox
                </label>
                <select
                  id="edit-space-sandbox-backend"
                  value={sandboxBackend}
                  onChange={(e) => setSandboxBackend(e.target.value)}
                  disabled={saving}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none text-sm disabled:opacity-50"
                >
                  {SANDBOX_BACKENDS.map((backend) => (
                    <option key={backend} value={backend}>
                      {backend}
                    </option>
                  ))}
                </select>
                <p className="mt-1 text-sm text-gray-500">
                  {sandboxBackendHelp(sandboxBackend)}
                </p>
              </div>

              <p className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-lg p-3">
                {EDIT_SPACE_CONSEQUENCE}
              </p>

              {saveError && (
                <p className="text-sm text-red-600" role="alert">
                  {saveError}
                </p>
              )}
            </>
          )}
        </div>

        <div className="px-6 py-4 border-t border-gray-200 bg-gray-50 flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={handleClose}
            className="px-4 py-2 rounded-lg text-sm font-medium text-gray-600 hover:bg-gray-100 transition-colors"
          >
            Cancel
          </button>
          {confirmPlan ? (
            <button
              type="button"
              onClick={() => save(true)}
              disabled={saving}
              className="px-4 py-2 rounded-lg text-sm font-medium text-white bg-amber-600 hover:bg-amber-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {saving ? "Saving..." : "Stop and save"}
            </button>
          ) : (
            <button
              type="button"
              onClick={() => save(false)}
              disabled={saving}
              className="px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {saving ? "Saving..." : "Save"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

export default EditSpaceDialog;

/**
 * The step between "save" and the save: what the edit would stop, and the user's
 * chance to say no.
 *
 * Not a refusal — the server is holding the space paused while it asks — so this
 * is a confirmation, not an error. `EDIT_SPACE_STOPS_WORK` says what continuing
 * costs and that cancelling costs nothing.
 */
function ConfirmStop({ plan, error }) {
  const agents = plan.agents ?? [];
  const jobs = plan.jobs ?? 0;

  return (
    <>
      <p className="text-sm text-gray-700">{EDIT_SPACE_STOPS_WORK}</p>

      <div className="rounded-lg border border-amber-200 bg-amber-50 p-3">
        <p className="text-sm font-medium text-amber-900">
          {agents.length === 0
            ? "No agent is working."
            : `${agents.length} ${agents.length === 1 ? "agent is" : "agents are"} working:`}
        </p>

        {agents.length > 0 && (
          <ul className="mt-1 space-y-0.5">
            {agents.map((agent) => (
              <li key={agent.name} className="text-sm text-amber-800">
                <span className="font-mono">{agent.name}</span>{" "}
                <span className="text-amber-700">({agent.status})</span>
                {agent.jobs > 0 && (
                  <span className="text-amber-700">
                    {" "}
                    — {agent.jobs} background{" "}
                    {agent.jobs === 1 ? "job" : "jobs"}
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}

        <p className="mt-1 text-sm text-amber-800">
          {jobs === 0
            ? "No background shell job is running."
            : `${jobs} background shell ${jobs === 1 ? "job" : "jobs"} will be stopped.`}
        </p>
      </div>

      {error && (
        <p className="text-sm text-red-600" role="alert">
          {error}
        </p>
      )}
    </>
  );
}

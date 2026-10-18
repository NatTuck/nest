/**
 * EditSpaceDialog — modal form for a space's **environment**: the workspace it
 * binds, whether its agents may reach the network, and which sandbox backend
 * runs them.
 *
 * One dialog for all three because they are one decision: every agent in the
 * space inherits them, and a save tells the live ones (`Agent.space_changed/2`)
 * rather than restarting anything. The consequence sentence is not decoration —
 * a *backend* change releases this space's container, and everything that lived
 * only there goes with it — so it is stated before the save, not after.
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
 *                 `network_access` and `sandbox_backend` initialize the form.
 */

import { useEffect, useState } from "react";
import { editSpace } from "../channels";
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
  "Saving restarts nothing, but every agent here is told. A backend change releases this space's container, so /tmp offloads, background-job logs and any running background job are lost.";

export function EditSpaceDialog({ open, onClose, space }) {
  const [workspacePath, setWorkspacePath] = useState("");
  const [networkAccess, setNetworkAccess] = useState(true);
  const [sandboxBackend, setSandboxBackend] = useState(DEFAULT_SANDBOX_BACKEND);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);

  // Initialize the form from the space's current values whenever the modal
  // opens (and again if the space's own values change under it, which a
  // `space:updated` frame from another session can do).
  useEffect(() => {
    if (open) {
      setWorkspacePath(space?.workspace_path ?? "");
      setNetworkAccess(space?.network_access === true);
      setSandboxBackend(space?.sandbox_backend ?? DEFAULT_SANDBOX_BACKEND);
      setSaving(false);
      setSaveError(null);
    }
  }, [open, space]);

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

  const handleSave = () => {
    const workspace = workspacePath.trim();
    if (!workspace) {
      setSaveError("Please enter a workspace path.");
      return;
    }

    setSaving(true);
    setSaveError(null);

    editSpace(
      space.id,
      {
        workspace_path: workspace,
        network_access: networkAccess,
        sandbox_backend: sandboxBackend,
      },
      () => {
        setSaving(false);
        onClose();
      },
      (err) => {
        setSaving(false);
        setSaveError(describeSpaceEditError(err));
      },
    );
  };

  const handleKeyDown = (e) => {
    if (e.key === "Escape") onClose();
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Edit space"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
      onKeyDown={handleKeyDown}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Edit space</h2>
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

        <div className="px-6 py-4 space-y-4">
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
                Whether this space's agents may reach the network. A space with
                no sandbox cannot enforce this.
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
        </div>

        <div className="px-6 py-4 border-t border-gray-200 bg-gray-50 flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 rounded-lg text-sm font-medium text-gray-600 hover:bg-gray-100 transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving}
            className="px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}

export default EditSpaceDialog;

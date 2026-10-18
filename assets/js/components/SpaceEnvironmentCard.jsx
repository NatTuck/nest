/**
 * The space's environment: its workspace, its network access, its sandbox
 * backend, and the way to edit them.
 *
 * A workspace, the network and the backend are the *space's* — every agent in it
 * inherits them — so they are shown and edited on the space rather than on one
 * of its agents. Read-only here, edited through `EditSpaceDialog`; the dialog is
 * the only writer.
 *
 * Extracted from the retired overview page (`/space/:slug/overview`), which the
 * feed replaced: the feed carries this card, and a campaign space's Main View
 * carries it below its play interface, so a space's environment is reachable
 * from every page of it.
 *
 * Missing data is stated rather than rendered blank: a space with no workspace
 * recorded is a space no agent in it can start in, and a backend this build does
 * not know is a value the reader has to see.
 */

import { useState } from "react";
import { EditSpaceDialog } from "./EditSpaceDialog";
import { SANDBOX_BACKENDS, sandboxBackendHelp } from "../utils/newSpaceForm";

export function SpaceEnvironmentCard({ space }) {
  const [editing, setEditing] = useState(false);

  return (
    <section
      aria-labelledby="space-environment-heading"
      className="rounded-lg border border-gray-200 bg-white p-4"
    >
      <h2
        id="space-environment-heading"
        className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3"
      >
        Environment
      </h2>

      <dl className="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
        <dt className="font-medium text-gray-700">Workspace</dt>
        <dd className="text-gray-600 font-mono break-all">
          {space.workspace_path || (
            <span className="text-red-600 font-sans">
              no workspace recorded for this space
            </span>
          )}
        </dd>
        <dt className="font-medium text-gray-700">Network access</dt>
        <dd className="text-gray-600">
          {space.network_access === true
            ? "Agents in this space can reach the network."
            : "Agents in this space cannot reach the network."}
          {space.sandbox_backend === "none" &&
            " This space has no sandbox, so nothing enforces that."}
        </dd>
        <dt className="font-medium text-gray-700">Sandbox</dt>
        <dd className="text-gray-600">
          {space.sandbox_backend || (
            <span className="text-red-600">
              no sandbox backend recorded for this space
            </span>
          )}
        </dd>
      </dl>

      {/* Only a backend this build knows gets its help line: the value itself is
          above, and `sandboxBackendHelp/1`'s fallback is worded for a *form*
          that offered a choice, which this is not. */}
      {SANDBOX_BACKENDS.includes(space.sandbox_backend) && (
        <p className="mt-3 text-sm text-gray-500">
          {sandboxBackendHelp(space.sandbox_backend)}
        </p>
      )}

      <button
        type="button"
        onClick={() => setEditing(true)}
        className="mt-4 px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors"
      >
        Edit space
      </button>

      <EditSpaceDialog
        open={editing}
        space={space}
        onClose={() => setEditing(false)}
      />
    </section>
  );
}

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
 * **Collapsed by default.** It is reference information, not something a reader
 * acts on every visit, and expanded it pushed the feed's notes down the page.
 *
 * Collapsing must not hide the one fact that makes a space unusable: a space
 * with no workspace recorded is a space no agent in it can start in, so the
 * summary row carries the workspace path — or its warning, in red — and only the
 * rest is behind the disclosure. That is the project's rule that missing data is
 * stated rather than left blank, applied to a control that hides things.
 *
 * Missing data elsewhere is stated the same way: a backend this build does not
 * know is a value the reader has to see.
 */

import { useState } from "react";
import { ChevronDown } from "./ChevronDown";
import { EditSpaceDialog } from "./EditSpaceDialog";
import { SANDBOX_BACKENDS, sandboxBackendHelp } from "../utils/newSpaceForm";

export function SpaceEnvironmentCard({ space }) {
  const [editing, setEditing] = useState(false);
  const [expanded, setExpanded] = useState(false);

  return (
    <section
      aria-labelledby="space-environment-heading"
      className="rounded-lg border border-gray-200 bg-white"
    >
      <h2 id="space-environment-heading">
        <button
          type="button"
          onClick={() => setExpanded((open) => !open)}
          aria-expanded={expanded}
          aria-controls={expanded ? "space-environment-body" : undefined}
          className="w-full flex items-center justify-between gap-3 p-4 text-left rounded-lg hover:bg-gray-50 transition-colors"
        >
          <span className="flex items-baseline gap-2 min-w-0">
            <span className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
              Environment
            </span>
            <span className="text-sm font-mono text-gray-600 truncate">
              {space.workspace_path || (
                <span className="text-red-600 font-sans">
                  no workspace recorded for this space
                </span>
              )}
            </span>
          </span>
          <ChevronDown rotated={expanded} />
        </button>
      </h2>

      {/* Mounted only when open, and `aria-controls` names it only then: an
          IDREF that resolves to nothing is an ARIA violation, so the attribute
          follows the element rather than pointing at a body that is not there.
          (Rendering it always and hiding it with `hidden` would fix the IDREF
          too, at the cost of the workspace appearing twice in the document.) */}
      {expanded && (
        <div id="space-environment-body" className="px-4 pb-4">
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

          {/* Only a backend this build knows gets its help line: the value itself
              is above, and `sandboxBackendHelp/1`'s fallback is worded for a
              *form* that offered a choice, which this is not. */}
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
        </div>
      )}

      {/* Outside the disclosure, so collapsing the card cannot hide an open
          dialog mid-edit. */}
      <EditSpaceDialog
        open={editing}
        space={space}
        onClose={() => setEditing(false)}
      />
    </section>
  );
}

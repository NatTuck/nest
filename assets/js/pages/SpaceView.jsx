/**
 * SpaceView — the space's own pages, both spellings.
 *
 * `/space/:slug` is the space's **Main View**, and the blueprint chooses it
 * (`main_view_config`):
 *
 *   * `{"view": "rpg"}` — the campaign's own page (a placeholder for now);
 *   * no config, or `{"view": "chat"}` — the default: **the root agent's
 *     chat**, reached with a `replace` redirect so the back button does not
 *     bounce through here (#96).
 *
 * `/space/:slug/overview` is the overview: the space's name, blueprint and
 * environment, plus its agents. It needs a path of its own because the default
 * Main View always applies — `create_space_with_root_agent/2` is the only
 * creation path, so a real space always has a root agent to redirect to, and
 * the overview would otherwise be a page nothing can reach. It is also where
 * the environment is *edited*, through `EditSpaceDialog`: a workspace, the
 * network and the sandbox backend are the space's, so they are edited on the
 * space rather than on one of its agents.
 *
 * The same page is what `/space/:slug` renders when there is nothing to
 * redirect to (a space whose root agent has not appeared yet), so the overview
 * has one definition and two ways in. It is reached from the sidebar's space
 * row, which is the space's own row and the only entry point that exists on
 * every page — a campaign's Main View has no agent header at all.
 *
 * A third case is an **archived** space: its sidebar row links here too, and the
 * space exists (it is stopped, not gone), so "Space not found" would be a lie.
 * It renders the archived notice with the same restore path the row's own button
 * pushes.
 *
 * ## Which page this is
 *
 * The `overview` flag comes from the route table (`App.jsx`), not from a second
 * reading of the path here. Two reasons: the route table is already the one place
 * that says which path is which page, and a prop at the call site (`<SpaceView
 * overview />`) reads as what it is. A `useMatch` on the overview's pattern would
 * put that pattern in a second place, where a change to one spelling could leave
 * the other silently matching nothing.
 */

import { useState } from "react";
import { Link, Navigate, useParams } from "react-router-dom";
import { useStore } from "../store";
import { unarchiveSpace } from "../channels";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { EditSpaceDialog } from "../components/EditSpaceDialog";
import { SpacePausedBanner } from "../components/SpacePausedBanner";
import { StatusDot } from "../components/StatusDot";
import { RpgPlayInterface } from "../components/RpgPlayInterface";
import { SANDBOX_BACKENDS, sandboxBackendHelp } from "../utils/newSpaceForm";

/**
 * Space View component. `overview` marks the explicit overview route: the Main
 * View dispatch below is the *space's* main screen, and the overview is a page
 * of its own rather than a fallback the main screen may or may not reach.
 */
export function SpaceView({ overview = false }) {
  const { spaceSlug } = useParams();
  const spaces = useStore((s) => s.spaces);
  const archivedSpaces = useStore((s) => s.archivedSpaces);
  const agents = useStore((s) => s.agents);
  const blueprints = useStore((s) => s.blueprints);

  const space = spaces.find((s) => s.slug === spaceSlug);
  // The space lives in exactly one of the two lists (`Nest.Spaces` keeps an
  // archived space out of the active set), so an archived slug is a space that
  // exists and is stopped — not a missing one.
  const archivedSpace = space
    ? null
    : archivedSpaces.find((s) => s.slug === spaceSlug);
  const resolved = space ?? archivedSpace;
  // The tab names the host and the space. The name falls back to the
  // slug when the store hasn't loaded the space yet (a hard load of a
  // deep URL) -- the slug is real information, so it beats a blank or
  // a placeholder. Both of the space's pages are the same page for this
  // purpose, so they share the title.
  useDocumentTitle([resolved?.name ?? spaceSlug]);

  if (!resolved) {
    return (
      <div className="max-w-4xl mx-auto py-12 text-center">
        <h1 className="text-2xl font-bold text-gray-900 mb-2">
          Space not found
        </h1>
        <Link to="/spaces" className="text-blue-600 hover:underline">
          Back to spaces
        </Link>
      </div>
    );
  }

  if (archivedSpace) {
    return <ArchivedSpace space={archivedSpace} />;
  }

  const blueprint = blueprints.find((b) => b.id === space.blueprint_id);
  const spaceAgents = agents.filter((a) => a.space_id === space.id);

  // The Main View dispatch. `main_view_config` is the blueprint's hook for
  // exactly this, and it has been on the schema since Phase 2.
  //
  // The overview route skips all of it: the overview is the space's own page
  // whatever its Main View is, which is also what gives a campaign space a
  // route to its environment.
  if (!overview) {
    const mainView = blueprint?.main_view_config?.view ?? "chat";

    if (mainView === "rpg") {
      // The pause banner belongs to the space, not to one of its pages: a
      // campaign space's Main View has no agent header and no overview in its
      // way, so without this it is the one screen where a paused space looks
      // exactly like a stuck one.
      return (
        <>
          <div className="max-w-4xl mx-auto">
            <SpacePausedBanner spaceId={space.id} spaceName={space.name} />
          </div>
          <RpgPlayInterface space={space} />
        </>
      );
    }

    // The default Main View is the root agent's chat. `parentId == null` is the
    // root: every other agent in the space was spawned by someone.
    const rootAgent = spaceAgents.find(
      (a) => (a.parentId ?? a.parent_id) == null,
    );

    if (rootAgent) {
      const base = `/space/${encodeURIComponent(space.slug)}`;
      return (
        <Navigate
          to={`${base}/agent/${encodeURIComponent(rootAgent.name)}`}
          replace
        />
      );
    }
  }

  return (
    <SpaceOverview
      space={space}
      blueprint={blueprint}
      spaceAgents={spaceAgents}
    />
  );
}

/**
 * What an archived space shows. Its sidebar row links here, and the space exists —
 * it is stopped, and its agents with it — so the answer is the notice and the way
 * back, not "Space not found". The restore is the same action the archived row's
 * own button pushes (`Nest.Spaces.unarchive_space/1` behind
 * `unarchive_space`); once it lands the store moves the space back into the active
 * list, this page re-renders as the space's real page, and the archived agents
 * appear in the sidebar's archived groups.
 */
function ArchivedSpace({ space }) {
  return (
    <div className="max-w-4xl mx-auto py-12 text-center">
      <h1 className="text-2xl font-bold text-gray-900 mb-2">{space.name}</h1>
      <p className="text-sm text-gray-600">
        This space is archived. Unarchive it to see its agents and its
        environment.
      </p>
      <button
        type="button"
        onClick={() => unarchiveSpace(space.id)}
        className="mt-4 px-4 py-2 rounded-lg text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 transition-colors"
      >
        Unarchive space
      </button>
      <p className="mt-4 text-sm">
        <Link to="/spaces" className="text-blue-600 hover:underline">
          Back to spaces
        </Link>
      </p>
    </div>
  );
}

/**
 * The space's overview page: its name and blueprint, its environment (read-only
 * here, edited through the dialog), and its agents with links to their chats.
 *
 * The agent list is also the way back to the chat, so the page is not a dead
 * end: the root agent is in it, and clicking it is what `/space/:slug` would
 * have redirected to.
 */
function SpaceOverview({ space, blueprint, spaceAgents }) {
  const [editing, setEditing] = useState(false);

  return (
    <div className="max-w-4xl mx-auto py-10">
      {/* The space's environment is being edited: work is held, and the user
          has to see that rather than agents that look stuck. First on the page,
          because a paused space is the one thing that explains everything
          below it. */}
      <SpacePausedBanner spaceId={space.id} spaceName={space.name} />

      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900">{space.name}</h1>
        {blueprint && (
          <p className="text-sm text-gray-500 mt-1">
            Blueprint: {blueprint.name}
          </p>
        )}

        {/* The space's environment, read-only here and edited through the
            dialog: a workspace, the network and the sandbox backend are the
            space's, so every agent in it inherits them. */}
        <div className="mt-4 rounded-lg border border-gray-200 bg-white p-4">
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
          {/* Only a backend this build knows gets its help line: the value
              itself is above, and `sandboxBackendHelp/1`'s fallback is worded
              for a *form* that offered a choice, which this is not. */}
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
      </div>

      <h2 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">
        Agents
      </h2>

      {spaceAgents.length === 0 ? (
        <p className="text-sm text-gray-400">No agents in this space yet.</p>
      ) : (
        <ul className="space-y-2">
          {spaceAgents.map((agent) => (
            <li
              key={agent.name}
              className="bg-white rounded-lg border border-gray-200 p-4 hover:border-blue-300 transition-colors"
            >
              <Link
                to={`/space/${encodeURIComponent(space.slug)}/agent/${encodeURIComponent(agent.name)}`}
                className="flex items-center justify-between"
              >
                <div className="flex items-center gap-3">
                  <StatusDot status={agent.status} className="w-2.5 h-2.5" />
                  <span className="text-sm font-medium text-gray-800">
                    {agent.name}
                  </span>
                  {agent.depth > 0 && (
                    <span className="text-xs text-gray-400">
                      (depth {agent.depth})
                    </span>
                  )}
                </div>
                <span className="text-xs text-gray-500">{agent.status}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}

      <EditSpaceDialog
        open={editing}
        space={space}
        onClose={() => setEditing(false)}
      />
    </div>
  );
}

export default SpaceView;

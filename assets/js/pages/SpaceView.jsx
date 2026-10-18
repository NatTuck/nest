/**
 * SpaceView — the space's own page, `/space/:slug`.
 *
 * The route is the space's **note feed** (`SpaceFeed`): the notes the human sent
 * and the notes agents sent them, with the space's environment and its composer.
 * It used to redirect to the root agent's chat (#96); that redirect is gone, and
 * so is `/space/:slug/overview`, whose content (the environment card and
 * `EditSpaceDialog`) the feed now carries.
 *
 * A blueprint may name a different Main View, and `main_view_config` is its hook
 * for exactly that: `{"view": "rpg"}` renders the campaign's own page
 * (`RpgPlayInterface`) instead. A campaign's main screen is not a note log, so
 * that selection stays — the feed is the *default* Main View, not the only one.
 * The environment card rides below it there, because the retired overview route
 * was the only way to a campaign space's environment from its main screen.
 *
 * Two routes remain, and they mean different things:
 *
 *   * `/space/:slug` — this page, the space's note log;
 *   * `/space/:slug/agent/:name` — that agent's own conversation, unchanged.
 *
 * They must not converge: the feed answers "what did we say to each other", the
 * agent page answers "what did this agent do".
 *
 * An **archived** space is a third case: its sidebar row links here too, and the
 * space exists (it is stopped, not gone), so "Space not found" would be a lie.
 * It renders the archived notice with the same restore path the row's own button
 * pushes.
 */

import { Link, useParams } from "react-router-dom";
import { useStore } from "../store";
import { unarchiveSpace } from "../channels";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { RpgPlayInterface } from "../components/RpgPlayInterface";
import { SpaceEnvironmentCard } from "../components/SpaceEnvironmentCard";
import { SpacePausedBanner } from "../components/SpacePausedBanner";
import { SpaceFeed } from "./SpaceFeed";

/**
 * Space View component. Which of the space's pages this is comes from the
 * blueprint (`main_view_config`), never from the path: the path says *which
 * space*, the blueprint says what its main screen is.
 */
export function SpaceView() {
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
  // deep URL) -- the slug is real information, so it beats a blank
  // or a placeholder.
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
  const mainView = blueprint?.main_view_config?.view ?? "chat";

  if (mainView === "rpg") {
    // The pause banner belongs to the space, not to one of its pages: a
    // campaign space's Main View has no agent header and no feed in its way, so
    // without this it is the one screen where a paused space looks exactly like
    // a stuck one. The environment card is here for the same reason the retired
    // overview existed — it is the only way to the space's settings from this
    // screen, and `RpgPlayInterface` itself is unchanged.
    return (
      <>
        <div className="max-w-4xl mx-auto">
          <SpacePausedBanner spaceId={space.id} spaceName={space.name} />
        </div>
        <RpgPlayInterface space={space} />
        <div className="max-w-4xl mx-auto pb-10">
          <SpaceEnvironmentCard space={space} />
        </div>
      </>
    );
  }

  return (
    <SpaceFeed space={space} blueprint={blueprint} spaceAgents={spaceAgents} />
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
        This space is archived. Unarchive it to see its notes, its agents and
        its environment.
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

export default SpaceView;

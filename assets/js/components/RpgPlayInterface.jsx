/**
 * The Tabletop RPG blueprint's Main View (#96).
 *
 * A space's main screen is whatever its blueprint's `main_view_config` says it
 * is. The default is the root agent's chat; a campaign space gets this page
 * instead, so clicking the space does not drop you into the game master's
 * transcript as if that were the whole interface.
 *
 * It is a placeholder on purpose: the play interface does not exist yet, and a
 * page that says so is more honest than the generic agent list pretending to be
 * one. When it is built, it replaces this component and `main_view_config`
 * stays the same.
 */

/**
 * @param {{ space: { name: string, slug: string } }} props
 */
export function RpgPlayInterface({ space }) {
  return (
    <div className="max-w-4xl mx-auto py-10">
      <h1 className="text-3xl font-bold text-gray-900">RPG Play Interface</h1>
      <p className="mt-1 text-sm text-gray-500">{space.name}</p>

      <div className="mt-8 rounded-lg border border-gray-200 bg-white p-6">
        <p className="text-gray-700">
          This space runs a tabletop campaign. The play interface is not built
          yet.
        </p>
        <p className="mt-3 text-sm text-gray-500">
          Until it is, open the game master&rsquo;s chat from the sidebar — the
          campaign is playable there.
        </p>
      </div>
    </div>
  );
}

export default RpgPlayInterface;

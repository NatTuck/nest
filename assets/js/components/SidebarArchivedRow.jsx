/**
 * A single archived space row in the sidebar. Archived spaces are stopped
 * and hidden from the main list; this row shows the name and a Restore
 * button that moves it back into the active list. Extracted from
 * `Sidebar` to keep that file under the source-line cap.
 */

import { Link } from "react-router-dom";
import { unarchiveSpace } from "../channels";

export function ArchivedSpaceRow({ space, location }) {
  const isCurrent = location.pathname === `/space/${space.slug}`;

  return (
    <li key={space.id}>
      <div
        className={`
          flex items-center justify-between rounded-lg group
          transition-colors duration-200
          ${isCurrent ? "bg-gray-200 text-gray-800" : "text-gray-500 hover:bg-gray-100"}
        `}
      >
        <Link
          to={`/space/${encodeURIComponent(space.slug)}`}
          className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
        >
          <div className="w-2 h-2 rounded-full flex-shrink-0 bg-gray-400" />
          <span className="truncate text-sm font-medium">{space.name}</span>
        </Link>
        <button
          type="button"
          onClick={() => unarchiveSpace(space.id)}
          className="mr-1 rounded border border-gray-300 px-2 py-0.5 text-xs text-gray-600 hover:bg-gray-200 opacity-0 group-hover:opacity-100 transition-opacity"
          aria-label={`Restore ${space.name}`}
          title="Restore space"
        >
          Restore
        </button>
      </div>
    </li>
  );
}

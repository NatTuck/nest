/**
 * SpacePausedBanner — the space's work is held while its environment is edited.
 *
 * `Nest.Agents.SpaceGate` pauses a space for the length of an environment edit:
 * a turn that arrives is queued, a tool call waits at the gate, and anything
 * already running is cancelled. That is the *server's* behaviour, and it is
 * invisible: an agent that is not answering looks broken. So every session that
 * can see the space shows this — the project's transparency rule — and it says
 * why, not just that something is wrong.
 *
 * Renders nothing when the space is not paused (there is nothing to say), and
 * the message names the space when it is.
 */
import { useStore } from "../store";

export function SpacePausedBanner({ spaceId, spaceName }) {
  const paused = useStore((s) => s.pausedSpaces.includes(spaceId));

  if (!paused) return null;

  return (
    <div role="status" className="bg-sky-50 border-l-4 border-sky-400 p-4 mb-4">
      <div className="flex items-start">
        <svg
          className="h-5 w-5 text-sky-400 mt-0.5 mr-3 flex-shrink-0 animate-spin"
          fill="none"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <circle
            className="opacity-25"
            cx="12"
            cy="12"
            r="10"
            stroke="currentColor"
            strokeWidth="4"
          />
          <path
            className="opacity-75"
            fill="currentColor"
            d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
          />
        </svg>
        <div>
          <p className="text-sky-900 text-sm font-medium">
            {spaceName ? `${spaceName} is paused` : "This space is paused"}
          </p>
          <p className="text-sky-800 text-sm">
            Its environment is being edited, so work is held: a new message
            waits until the edit finishes, a tool call waits at the gate, and
            anything that was already running was cancelled — the agent was told
            why and can re-issue it. Nothing is lost.
          </p>
        </div>
      </div>
    </div>
  );
}

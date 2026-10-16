/**
 * Initial loading state shown while the agent channel's first join is in
 * flight. Extracted from `ChatPage`.
 *
 * It names the agent it is waiting for. This state is the only feedback the
 * user has that the click they just made did anything, and for a cold agent
 * the wait covers starting the agent's process as well as the join — long
 * enough that a bare spinner leaves them unsure the click registered.
 */

/**
 * @param {object} props
 * @param {string} [props.name] — the agent being loaded, as the route names
 *   it. Omitted only by a caller that has no agent to name.
 */
export function ChatLoading({ name }) {
  return (
    <div
      className="flex items-center justify-center h-full"
      role="status"
      aria-label={name ? `Loading ${name}` : "Loading agent"}
    >
      <div className="flex flex-col items-center gap-4">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600" />
        <p className="text-gray-600">
          {name ? `Loading ${name}...` : "Loading agent..."}
        </p>
      </div>
    </div>
  );
}

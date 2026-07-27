/**
 * MessagesList — committed messages from the agent cache.
 *
 * Subscribes ONLY to `cache.messages` via a granular selector
 * (zustand compares the returned array reference, so the
 * component only re-renders when `messages` is actually
 * replaced — typically on a `chat:message` broadcast that
 * appends a new entry).
 *
 * Critically, this component does NOT subscribe to `partial`,
 * `streaming`, or any other delta-driven field. During
 * streaming, the agent's `cache.partial` updates 10–50 times
 * per second and the store replaces `cache` on every update,
 * but `cache.messages` is preserved across those updates. The
 * reference-stable selector therefore short-circuits the
 * re-render entirely — the 200-message list at 100k tokens
 * does NOT touch React on every delta.
 *
 * The streaming message itself is rendered by
 * `StreamingMessage`, which subscribes to `partial` separately.
 */

import { useStore } from "../store";
import { MessageBubble } from "./Message";

const EMPTY_MESSAGES = [];

export function MessagesList({ agentName }) {
  const messages = useStore(
    (state) => state.agentsCache[agentName]?.messages ?? EMPTY_MESSAGES,
  );

  return messages.map((message) => (
    <MessageBubble
      key={message.index}
      message={message}
      agentName={agentName}
    />
  ));
}

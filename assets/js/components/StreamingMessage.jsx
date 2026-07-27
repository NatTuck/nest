/**
 * StreamingMessage — the in-flight partial message bubble.
 *
 * Subscribes ONLY to `cache.partial`. The store replaces
 * `cache` on every `chat:delta` (which updates `partial` only),
 * so this component re-renders on every delta — but the
 * 200-message `cache.messages` list does NOT, because
 * `MessagesList` subscribes to that slice separately and the
 * array reference is preserved across deltas.
 *
 * Renders nothing when `partial` is null (the agent is not
 * currently streaming). The bubble uses the same `MessageBubble`
 * component as committed messages, with the `isPartial` flag
 * flipped on so the "(typing…)" indicator and the trailing
 * `StreamingDots` render.
 */

import { useStore } from "../store";
import { MessageBubble } from "./Message";

export function StreamingMessage({ agentName }) {
  const partial = useStore(
    (state) => state.agentsCache[agentName]?.partial ?? null,
  );

  if (!partial) return null;

  return (
    <MessageBubble
      message={{ ...partial, isPartial: true }}
      agentName={agentName}
    />
  );
}

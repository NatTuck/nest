/**
 * Message — single message bubble for the chat UI.
 *
 * Renders one entry from `cache.messages` (committed) or the
 * in-flight `cache.partial` (when wrapped in `{ ...partial,
 * isPartial: true }`). The shape is identical for both — the
 * `isPartial` flag drives the "(typing…)" indicator and the
 * trailing `StreamingDots`.
 *
 * This is a `React.memo`'d component: a parent re-render
 * (e.g. `MessagesList` rebuilding after a new message lands,
 * or `StreamingMessage` rebuilding after a delta) only
 * re-renders the messages whose own props actually changed.
 * The other props (`message`, `agentName`) are stable refs
 * per message; the default `Object.is` comparison short-
 * circuits the body of the function for the unchanged
 * siblings.
 *
 * The per-message work that DOES still run on a parent
 * re-render is the `messageToMarkdown` closure wired to the
 * `CopyButton` — but it's stored as a `getText` callback, not
 * eagerly materialized, so the markdown join is deferred
 * until the user actually clicks. The `toolCalls` /
 * `toolResults` JSON.stringify calls inside `ToolCalls` and
 * `ToolResults` are still eager; those are the next biggest
 * perf wins if this ever needs to go further.
 */
import { memo } from "react";

import { CopyButton } from "./CopyButton";
import { ThinkingBlock } from "./ThinkingBlock";
import { MessageContent } from "./MessageContent";
import { ToolCalls } from "./ToolCalls";
import { ToolResults } from "./ToolResults";
import { ApiLogsBlock } from "./ApiLogsBlock";
import { SystemMessageContent } from "./SystemMessageContent";
import { StreamingDots } from "./StreamingDots";

import { messageToMarkdown } from "../utils/formatMessage.js";
import { messageText } from "../utils/messageText.js";
import { thinkingFor, textPartsFor } from "../utils/messageParts.js";
import { stripModePrefix } from "../utils/stripModePrefix.js";

function Message({ message, agentName }) {
  const isUser = message.role === "user";
  const isSystem = message.role === "system";
  const isTool = message.role === "tool";
  const isPartial = message.isPartial ?? false;

  const bubbleClass = isUser
    ? "bg-blue-50 ml-12"
    : isSystem
      ? "bg-amber-50 border border-amber-200 mx-8"
      : isTool
        ? "bg-green-50 border border-green-200 mx-8"
        : "bg-gray-50 mr-12";

  const avatarClass = isUser
    ? "bg-blue-600 text-white"
    : isSystem
      ? "bg-amber-500 text-white"
      : isTool
        ? "bg-green-500 text-white"
        : "bg-gray-600 text-white";

  const avatarLabel = isUser ? "U" : isSystem ? "S" : isTool ? "T" : "AI";

  const roleLabel = isUser
    ? "You"
    : isSystem
      ? "System"
      : isTool
        ? "Tool Result"
        : agentName;

  return (
    <div className={`flex gap-4 p-4 rounded-xl ${bubbleClass}`}>
      {/* Avatar */}
      <div
        className={`w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0 ${avatarClass}`}
      >
        {avatarLabel}
      </div>

      {/* Message content */}
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 mb-1">
          <span className="font-semibold text-sm text-gray-700">
            {roleLabel}
          </span>
          {isUser && message.mode && (
            <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 text-blue-700 font-medium">
              mode: {message.mode}
            </span>
          )}
          {isPartial && (
            <span className="text-xs text-gray-400">(typing...)</span>
          )}
          <span className="ml-auto">
            <CopyButton
              getText={() => messageToMarkdown(message)}
              label="Copy message"
            />
          </span>
        </div>
        {/* Thinking is rendered BEFORE the reply and stays in
            place across the partial → final transition. The box
            always starts expanded (the user wanted the reasoning
            to remain visible after the turn completes) and the
            user can collapse it manually — no `key` re-mount is
            needed since the box's state doesn't need to change
            on finalization. See
            `assets/js/components/ThinkingBlock.jsx` for the full
            rationale. */}
        <ThinkingBlock
          thinking={thinkingFor(message)}
          isPartial={isPartial}
          hasVisibleContent={messageText(message).trim().length > 0}
        />
        {isSystem ? (
          <SystemMessageContent parts={message.parts} isPartial={isPartial} />
        ) : (
          <MessageContent
            parts={
              isUser
                ? [
                    {
                      kind: "text",
                      text: stripModePrefix(messageText(message), message.mode),
                    },
                  ]
                : textPartsFor(message)
            }
            isPartial={isPartial}
            className="text-gray-800"
          />
        )}
        <ToolCalls toolCalls={message.toolCalls} />
        <ToolResults toolResults={message.toolResults} />
        <ApiLogsBlock apiLogs={message.apiLogs} />
        {isPartial && (
          <div className="mt-2">
            <StreamingDots
              size="lg"
              colorClass="bg-gray-400"
              ariaLabel="Streaming message"
            />
          </div>
        )}
      </div>
    </div>
  );
}

// `message` is the primary identity for a bubble — the same
// message object reference is reused across re-renders unless
// the store actually replaces it. `agentName` is the URL
// parameter and is stable for the lifetime of the page. The
// default `Object.is` comparison short-circuits the function
// body for siblings whose `message` ref is unchanged.
export const MessageBubble = memo(Message);

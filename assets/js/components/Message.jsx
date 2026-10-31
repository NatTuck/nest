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
 * until the user actually clicks. That join serialises the
 * whole message in part order and deliberately omits thinking
 * (issue #51): the UI still renders thinking via
 * `ThinkingBlock`, only the clipboard leaves it out. The copy
 * control sits in a bottom actions row, below everything it
 * copies, so its position matches its payload; for a partial
 * message the streaming indicator follows it. The
 * `toolCalls` / `toolResults` JSON.stringify calls inside
 * `ToolCalls` and `ToolResults` are still eager; those are the
 * next biggest perf wins if this ever needs to go further.
 */
import { memo } from "react";

import { CopyButton } from "./CopyButton";
import { ThinkingBlock } from "./ThinkingBlock";
import { MessageContent } from "./MessageContent";
import { UserMessageParts } from "./UserMessageParts.jsx";
import { ToolCalls } from "./ToolCalls";
import { ToolResults } from "./ToolResults";
import { ToolMedia } from "./ToolMedia.jsx";
import { DelegatedTask } from "./DelegatedTaskBlock";
import { ApiLogsBlock } from "./ApiLogsBlock";
import { SystemMessageContent } from "./SystemMessageContent";
import { StreamingDots } from "./StreamingDots";

import { messageToMarkdown } from "../utils/formatMessage.js";
import { messageText } from "../utils/messageText.js";
import { rowAppearance } from "../utils/header.js";
import { ReplyRequiredChip } from "./SenderCaption.jsx";
import {
  thinkingFor,
  messageContentPartsFor,
  toolCallsFromParts,
  mediaFromParts,
} from "../utils/messageParts.js";

function Message({ message, agentName }) {
  const isUser = message.role === "user";
  const isSystem = message.role === "system";
  const isTool = message.role === "tool";
  const isPartial = message.isPartial ?? false;

  // Derive tool calls from the canonical `parts` shape so
  // streaming partials (whose `message.toolCalls` is never
  // populated — only the finalized message sets that field)
  // render in-flight tool calls as soon as the BEAM broadcasts
  // them. For finalized messages the derived value matches
  // `message.toolCalls`, so this is just a more robust read.
  const toolCalls =
    toolCallsFromParts(message.parts) ?? message.toolCalls ?? [];

  // A user row's identity comes from its bodies' headers, not from the role: the
  // role is overloaded on the wire (a drained batch, a peer's note, a runtime
  // notice and a spawn kickoff are all user rows), so "You" is only right when
  // the server says these are the human's own words (`origin: "human"`).
  // `rowAppearance` decides the label, the tint and the avatar from
  // `rowSenders`, so the row and its per-body captions cannot disagree.
  const sender = isUser ? rowAppearance(message) : null;

  const bubbleClass = sender
    ? `${sender.bubble} ml-12`
    : isSystem
      ? "bg-amber-50 border border-amber-200 mx-8"
      : isTool
        ? "bg-green-50 border border-green-200 mx-8"
        : "bg-gray-50 mr-12";

  const avatarClass = sender
    ? sender.avatar
    : isSystem
      ? "bg-amber-500 text-white"
      : isTool
        ? "bg-green-500 text-white"
        : "bg-gray-600 text-white";

  const avatarLabel = sender
    ? sender.avatarLabel
    : isSystem
      ? "S"
      : isTool
        ? "T"
        : "AI";

  const roleLabel = sender
    ? sender.label
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
          {/* The reply marker is row-level only when the row holds one body: a
              multi-body row carries it in each body's caption
              (`UserMessageParts`), so nothing is shown twice. */}
          {sender?.replyRequired && <ReplyRequiredChip />}
          {isPartial && (
            <span className="text-xs text-gray-400">(typing...)</span>
          )}
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
        ) : isUser ? (
          // A user row is rendered segment by segment: its text parts are not
          // uniformly prose (a backgrounded command's output is one of them),
          // and it renders its own media. `UserMessageParts` owns both.
          <UserMessageParts message={message} className="text-gray-800" />
        ) : (
          <MessageContent
            parts={messageContentPartsFor(message)}
            isPartial={isPartial}
            className="text-gray-800"
          />
        )}
        <ToolCalls toolCalls={toolCalls} />
        <DelegatedTask message={message} agentName={agentName} />
        <ToolResults toolResults={message.toolResults} />
        {/* The media for a row that is not the user's own: `UserMessageParts`
            renders a user row's attachments itself, and every other role
            either gets parts with the media filtered out
            (`messageContentPartsFor`) or, for `system`, goes through
            `SystemMessageContent` — so this is the one render.
            `message.media` is derived by `buildMerged`; a freshly appended row
            carries no message-level field, so the `mediaFromParts` fallback
            covers the media part in `parts`. The `?.length` test is not `??`:
            an empty `media` array is not nullish, so `??` would keep it and
            drop an attachment whose only copy is that part. */}
        {!isUser && (
          <ToolMedia
            media={
              message.media?.length
                ? message.media
                : mediaFromParts(message.parts)
            }
          />
        )}
        <ApiLogsBlock
          apiLogs={message.apiLogs}
          agentName={agentName}
          index={message.index}
          messageRole={message.role}
          expectsResponseLog={
            message.role === "assistant" &&
            !message.metadata?.error &&
            !message.metadata?.stopped_by_user
          }
        />
        {/* Actions row. The copy control lives at the bottom of the
            bubble, below everything it copies, so its position matches
            its payload (the whole message except thinking). */}
        <div
          data-testid="message-actions"
          className="mt-2 flex items-center justify-end"
        >
          <CopyButton
            getText={() => messageToMarkdown(message)}
            label="Copy message"
          />
        </div>
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

/**
 * DelegatedTaskBlock — renders an `agents-spawn` tool call
 * (with a `query`) as a first-class "delegated task" card so
 * the conversation reads as a tree of subtasks rather than as
 * another tool use.
 *
 * The block shows:
 *
 *   - The query text the parent sent to the child.
 *   - The child's name, linked to its chat page. The only
 *     route that renders a chat is
 *     `/space/:spaceSlug/agent/:name`, so the link is
 *     space-scoped and the slug comes from the route (see
 *     `DelegatedTaskBlock` below).
 *   - Status: "running" while the parent is blocked on the
 *     tool worker; "async" when the call passed `async: true`
 *     (the paired result is only a confirmation, the real
 *     answer arrives later as a message); "completed" once
 *     the matching `:tool_result` lands next to it; "error"
 *     if the result came back with `is_error: true`.
 *   - The child's response content (truncated to a
 *     reasonable preview; the full text is in the
 *     `:tool` message right next to the tool call).
 *
 * The block is rendered inside the assistant message's
 * `MessageBubble`, after its `ToolCalls` block. This puts
 * the card visually between the assistant message and the
 * matching `ToolResults` block (which lives in a separate
 * `:tool` message). `DelegatedTask` reads `agents-spawn`
 * tool calls from a single assistant message and pairs them
 * with their results by `tool_call_id`.
 */

import { Link, useParams } from "react-router-dom";
import { useStore } from "../store";

const EMPTY_MESSAGES = [];

const STREAMING_PLACEHOLDER = "(receiving instruction…)";

/**
 * Pull the `query` field out of an `agents-spawn` tool
 * call's arguments, in any of the shapes it can take:
 *
 *   - Already-parsed object (`{ query: "do X" }`) →
 *     return the field.
 *   - Streaming partial buffer (e.g.
 *     `'{"query":"do X'` or `'{"query":"do X\\nX"'`).
 *     Try `JSON.parse` for fully-formed prefixes; on failure,
 *     fall back to a regex that pulls whatever substring is
 *     inside the open `"query":"` marker. Returns
 *     `null` while the buffer is too small to contain any
 *     query text (e.g. `'{"que'`).
 */
function extractCloneInstruction(args) {
  if (args == null) return null;
  if (typeof args === "object") {
    return args.query ?? null;
  }
  if (typeof args !== "string") return null;

  try {
    const parsed = JSON.parse(args);
    if (parsed && typeof parsed === "object" && parsed.query) {
      return parsed.query;
    }
  } catch {
    // fall through — partial buffer; use the regex fallback
  }

  // Snip whatever lives inside `"query":"<chars>` for
  // early buffers. The capture stops at the next unescaped
  // quote (escaped `\"` is consumed but not split on). The
  // regex is just for visual streaming UX — the finalized
  // `addChatMessage` reassembles the full string.
  const match = args.match(/"query"\s*:\s*"((?:[^"\\]|\\.)*)/);
  if (match) return match[1];
  return null;
}

/**
 * Read the `async` flag out of an `agents-spawn` tool call's
 * arguments, tolerating the same shapes as
 * `extractCloneInstruction`: a parsed object, a fully-formed
 * streaming JSON string, or a partial buffer.
 *
 * With `async: true` the paired tool result is only a
 * confirmation — the child's real response arrives later as a
 * separate inbox message — so the card must not present that
 * confirmation as the child's response.
 */
function extractAsyncFlag(args) {
  if (args == null) return false;
  if (typeof args === "object") {
    return args.async === true;
  }
  if (typeof args !== "string") return false;

  try {
    const parsed = JSON.parse(args);
    if (parsed && typeof parsed === "object") {
      return parsed.async === true;
    }
  } catch {
    // fall through — partial buffer; use the regex fallback
  }

  return /"async"\s*:\s*true/.test(args);
}

/**
 * Read the child's `name` out of an `agents-spawn` tool call's
 * arguments, tolerating the same shapes as
 * `extractCloneInstruction`/`extractAsyncFlag`: a parsed
 * object, a fully-formed streaming JSON string, or a partial
 * buffer. `name` is a required argument, so a committed call
 * always resolves; a `null` result means the call is still
 * mid-stream or genuinely malformed.
 */
function extractChildName(args) {
  if (args == null) return null;
  if (typeof args === "object") {
    return args.name ?? null;
  }
  if (typeof args !== "string") return null;

  try {
    const parsed = JSON.parse(args);
    if (parsed && typeof parsed === "object" && parsed.name) {
      return parsed.name;
    }
  } catch {
    // fall through — partial buffer; use the regex fallback
  }

  const match = args.match(/"name"\s*:\s*"((?:[^"\\]|\\.)*)/);
  if (match) return match[1];
  return null;
}

/**
 * The child's name, linked to its chat page inside the current
 * space. The only route that renders a chat is
 * `/space/:spaceSlug/agent/:name`, so the link needs the space
 * slug and a link without one (`/agent/:name`) matches no route
 * at all and renders a blank page. When the slug is unavailable
 * (the card is being rendered outside its route) the name is
 * shown with an explicit indicator instead of a dead link.
 */
function ChildNameLink({ childName, spaceSlug }) {
  if (!spaceSlug) {
    return (
      <span
        data-testid="delegated-task-space-missing"
        className="text-amber-700"
      >
        {childName} — chat link unavailable: no space in the route
      </span>
    );
  }

  return (
    <Link
      to={`/space/${encodeURIComponent(spaceSlug)}/agent/${encodeURIComponent(childName)}`}
      className="text-indigo-600 hover:underline font-mono"
    >
      {childName}
    </Link>
  );
}

/**
 * Render one `DelegatedTaskBlock` per `agents-spawn` tool
 * call (with a `query`) in a single assistant message. Mounted
 * inside `MessageBubble`, between `<ToolCalls />` and
 * `<ToolResults />`, so the card sits inline with the
 * conversation flow rather than stacking at the bottom of
 * the chat log.
 *
 * Pairs each call with its matching `:tool_result` from the
 * agent's committed messages via `tool_call_id`; an
 * unmatched call renders as "Running". Subscribes to
 * `cache.messages` only — the streaming partial is rendered
 * through the same `MessageBubble` path, so a single
 * component covers both committed and in-flight messages.
 * Returns null when the message has no `agents-spawn` calls,
 * so there's no rendering cost for the common case.
 *
 * Tolerates either snake_case (`tool_calls`,
 * `tool_results`, `tool_call_id`, `is_error`) or camelCase
 * (`toolCalls`, `toolResults`, `toolCallId`, `isError`) keys
 * — both shapes exist in the cache depending on which
 * message batch populated it.
 */
export function DelegatedTask({ message, agentName }) {
  const messages = useStore(
    (state) => state.agentsCache[agentName]?.messages ?? EMPTY_MESSAGES,
  );

  const calls = message.toolCalls || message.tool_calls || [];
  const cloneCalls = [];
  for (const c of calls) {
    if (c && c.name === "agents-spawn") {
      cloneCalls.push(c);
    }
  }
  if (cloneCalls.length === 0) return null;

  // Build a map of tool_call_id → result. Results live in
  // tool messages that follow the calling assistant message;
  // we don't strictly require ordering — index match is
  // enough for the tool-call pairing wire format.
  const resultById = new Map();
  for (const m of messages) {
    const results = m.toolResults || m.tool_results || [];
    for (const r of results) {
      const id = r.tool_call_id ?? r.toolCallId;
      if (id) resultById.set(id, r);
    }
  }

  return (
    <div className="mt-2 space-y-2">
      {cloneCalls.map((call) => {
        const result = resultById.get(call.id);
        const resultContent = result?.content ?? null;
        // Extract the query from the (possibly
        // streaming) arguments. Falls back to the legacy
        // `call.input.query` shape for messages that
        // pre-date the streaming-args refactor.
        const rawArgs =
          call.arguments !== undefined ? call.arguments : call.input;
        const extracted = extractCloneInstruction(rawArgs);
        const instruction =
          extracted != null
            ? extracted
            : typeof rawArgs === "string"
              ? STREAMING_PLACEHOLDER
              : "";
        return (
          <DelegatedTaskBlock
            key={call.id}
            toolCallId={call.id}
            instruction={instruction}
            childName={extractChildName(rawArgs)}
            response={result ? resultContent : null}
            isError={
              result ? (result.is_error ?? result.isError ?? false) : false
            }
            isAsync={extractAsyncFlag(rawArgs)}
          />
        );
      })}
    </div>
  );
}

/**
 * The space slug used to build the child's chat link comes from
 * the route (`useParams`) rather than from a prop: this card is
 * only ever mounted under `ChatPage`'s
 * `/space/:spaceSlug/agent/:name` route, and reading the route
 * param is how `ChatPage`/`SpaceView` resolve the slug. A link
 * to `/agent/:name` (no space) matches no route at all and
 * renders a blank page, so a missing slug renders an explicit
 * "link unavailable" indicator instead of a dead link.
 *
 * @param {Object} props
 * @param {string} props.toolCallId
 * @param {string} props.instruction
 *   The query that was passed to `agents-spawn`.
 * @param {string|null} props.childName
 *   The child's name, read from the `agents-spawn` call's
 *   `arguments.name`. `null` while the call is still
 *   streaming (or if it is malformed); the card then shows
 *   an explicit "missing" indicator rather than hiding the
 *   row, so the drill-down affordance is never silently
 *   absent.
 * @param {string|null} props.response
 *   The child's final assistant text (or the error
 *   string). `null` while the tool worker is still
 *   blocked. With `isAsync` this is only the spawn
 *   confirmation, not the child's answer.
 * @param {boolean} [props.isError]
 *   True when the synthetic tool result came back with
 *   `is_error: true`. Default false.
 * @param {boolean} [props.isAsync]
 *   True when the call passed `async: true`. The paired
 *   result is then only a confirmation; the child's real
 *   response arrives later as a separate inbox message (see
 *   the async note below for the two ways that delivery can
 *   fail), so the card shows an "Async" state instead of a
 *   "Completed" child response. Default false.
 */
export function DelegatedTaskBlock({
  toolCallId,
  instruction,
  childName,
  response,
  isError = false,
  isAsync = false,
}) {
  const { spaceSlug } = useParams();

  const status = isError
    ? "error"
    : isAsync
      ? "async"
      : response
        ? "completed"
        : "running";

  const statusLabel = {
    running: "Running",
    async: "Async",
    completed: "Completed",
    error: "Failed",
  }[status];

  const statusClasses = {
    running: "bg-amber-100 text-amber-700",
    async: "bg-sky-100 text-sky-700",
    completed: "bg-emerald-100 text-emerald-700",
    error: "bg-red-100 text-red-700",
  }[status];

  return (
    <div
      data-testid="delegated-task-block"
      data-tool-call-id={toolCallId}
      className="mt-3 rounded-lg border border-indigo-200 bg-indigo-50 p-3"
    >
      <div className="flex items-center gap-2 text-indigo-800 font-medium text-sm">
        <svg
          className="w-4 h-4"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-label="Branch icon"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M7 7h3v10H7zM14 7h3v10h-3zM3 7h2a2 2 0 012 2v6a2 2 0 01-2 2H3zM19 7h2a2 2 0 012 2v6a2 2 0 01-2 2h-2"
          />
        </svg>
        <span>Delegated task</span>
        <span
          className={`ml-auto text-xs font-mono px-2 py-0.5 rounded-full ${statusClasses}`}
        >
          {statusLabel}
        </span>
      </div>
      <p className="mt-2 text-xs text-indigo-700">
        {childName ? (
          <ChildNameLink childName={childName} spaceSlug={spaceSlug} />
        ) : (
          <span
            data-testid="delegated-task-child-missing"
            className="text-amber-700"
          >
            child name unavailable
          </span>
        )}
      </p>
      {instruction && (
        <>
          <p className="mt-2 text-xs text-indigo-700 font-medium">
            Instruction
          </p>
          <pre
            data-testid="delegated-task-instruction"
            className="mt-1 text-xs whitespace-pre-wrap break-words bg-white border border-indigo-100 rounded p-2 italic text-indigo-800"
          >
            {instruction}
          </pre>
        </>
      )}
      {/* The async note is deliberately static: the waiter
          delivers the child's answer as an ordinary inbox
          message with no `tool_call_id` on it, so there is
          nothing to correlate with this card and no way to flip
          it to a "done" state once the answer lands. Issue #31
          reworks this delivery path; until then the card can
          only state what is expected to happen, not whether it
          did. */}
      {status === "async" && (
        <p
          data-testid="delegated-task-async-note"
          className="mt-2 text-xs text-sky-700"
        >
          The response arrives later as a message. A Stop does not cancel the
          waiter, so a timeout notice may arrive instead; a result this agent
          refuses is lost.
        </p>
      )}
      {response && status === "async" && (
        <>
          <p className="mt-2 text-xs text-indigo-700 font-medium">
            Confirmation
          </p>
          <pre
            data-testid="delegated-task-confirmation"
            className="mt-1 text-xs whitespace-pre-wrap break-words bg-white border border-indigo-100 rounded p-2 text-indigo-800"
          >
            {response}
          </pre>
        </>
      )}
      {response && (status === "completed" || status === "error") && (
        <>
          <p
            className={`mt-2 text-xs font-medium ${isError ? "text-red-700" : "text-indigo-700"}`}
          >
            {isError ? "Error" : "Child response"}
          </p>
          <pre
            data-testid="delegated-task-response"
            className={`mt-1 text-xs whitespace-pre-wrap break-words bg-white border rounded p-2 ${
              isError
                ? "border-red-100 text-red-800"
                : "border-indigo-100 text-indigo-900"
            }`}
          >
            {response}
          </pre>
        </>
      )}
    </div>
  );
}

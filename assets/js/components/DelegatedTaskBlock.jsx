/**
 * DelegatedTaskBlock — renders a `clone_agent` tool call as a
 * first-class "delegated task" card so the conversation reads
 * as a tree of subtasks rather than as another tool use.
 *
 * The block shows:
 *
 *   - The instruction text the parent sent to the child.
 *   - The child's name (linked to its chat page so the user
 *     can drill down into the child's full conversation).
 *   - Status: "running" while the parent is blocked on the
 *     tool worker; "completed" once the matching
 *     `:tool_result` lands next to it; "error" if the result
 *     came back with `is_error: true`.
 *   - The child's response content (truncated to a
 *     reasonable preview; the full text is in the
 *     `:tool` message right next to the tool call).
 *
 * The block is rendered inside the assistant message's
 * `MessageBubble`, after its `ToolCalls` block. This puts
 * the card visually between the assistant message and the
 * matching `ToolResults` block (which lives in a separate
 * `:tool` message). `DelegatedTask` reads `clone_agent`
 * tool calls from a single assistant message and pairs them
 * with their results by `tool_call_id`.
 */

import { Link } from "react-router-dom";
import { useStore } from "../store";

const EMPTY_MESSAGES = [];

/**
 * Render one `DelegatedTaskBlock` per `clone_agent` tool
 * call in a single assistant message. Mounted inside
 * `MessageBubble`, between `<ToolCalls />` and
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
 * Returns null when the message has no `clone_agent` calls,
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
    if (c && c.name === "clone_agent") {
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
        // For now we surface the response content; the
        // child_name from a successful spawn is the next
        // child that registered itself in the AgentsRegistry.
        // The Tools worker already includes a stable
        // identifier in the result content if we want to
        // surface it as a link later.
        return (
          <DelegatedTaskBlock
            key={call.id}
            toolCallId={call.id}
            instruction={
              call.arguments?.instruction ?? call.input?.instruction ?? ""
            }
            response={result ? resultContent : null}
            isError={
              result ? (result.is_error ?? result.isError ?? false) : false
            }
          />
        );
      })}
    </div>
  );
}

/**
 * @param {Object} props
 * @param {string} props.toolCallId
 * @param {string} props.instruction
 *   The instruction that was passed to `clone_agent`.
 * @param {string|null} props.childName
 *   The child's name (parsed from the matching
 *   `:tool_result` if the parent stored it; `null` while
 *   the tool worker is still blocked or if the spawn
 *   failed).
 * @param {string|null} props.response
 *   The child's final assistant text (or the error
 *   string). `null` while the tool worker is still
 *   blocked.
 * @param {boolean} [props.isError]
 *   True when the synthetic tool result came back with
 *   `is_error: true`. Default false.
 */
export function DelegatedTaskBlock({
  toolCallId,
  instruction,
  childName,
  response,
  isError = false,
}) {
  const status = isError ? "error" : response ? "completed" : "running";

  const statusLabel = {
    running: "Running",
    completed: "Completed",
    error: "Failed",
  }[status];

  const statusClasses = {
    running: "bg-amber-100 text-amber-700",
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
      {childName && (
        <p className="mt-2 text-xs text-indigo-700">
          <Link
            to={`/agent/${encodeURIComponent(childName)}`}
            className="text-indigo-600 hover:underline font-mono"
          >
            {childName}
          </Link>
        </p>
      )}
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
      {response && status !== "running" && (
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

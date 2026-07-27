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
 * The block is rendered between an assistant message's
 * `ToolCalls` block and the matching `ToolResults` block
 * (in the next assistant or tool message). `DelegatedTasks`
 * collects `clone_agent` calls from the messages list and
 * pairs them with their results.
 */

import { Link } from "react-router-dom";
import { useStore } from "../store";

const EMPTY_MESSAGES = [];

/**
 * Look across the agent's message list for `clone_agent`
 * tool calls (in `assistant` messages) and their matching
 * tool results (in `tool` messages), then render a
 * DelegatedTaskBlock for each pair. Pairs are matched by
 * `tool_call_id`; an unmatched call renders as "running".
 *
 * Subscribes to `cache.messages` and `cache.partial` via
 * granular selectors. The component re-renders when either
 * slice changes, but during streaming only `partial` changes
 * — `messages` is preserved across deltas, so the body
 * falls through the same `cloneCalls` rebuild path on
 * every delta. The work is O(N) over messages (where N is
 * the count of `clone_agent` calls) which is small in
 * practice.
 *
 * Mounted alongside the existing `ToolCalls` / `ToolResults`
 * blocks in the chat page; the user sees the same response
 * through two lenses — the raw tool use AND the sub-agent
 * tree view.
 */
export function DelegatedTasks({ agentName }) {
  const messages = useStore(
    (state) => state.agentsCache[agentName]?.messages ?? EMPTY_MESSAGES,
  );
  const partial = useStore(
    (state) => state.agentsCache[agentName]?.partial ?? null,
  );

  const cloneCalls = [];
  for (const m of messages) {
    const calls = m.toolCalls || m.tool_calls || [];
    for (const c of calls || []) {
      if (c.name === "clone_agent") {
        cloneCalls.push({ call: c, ownerIndex: m.index });
      }
    }
  }
  if (partial && partial.role === "assistant") {
    const calls = partial.toolCalls || partial.tool_calls || [];
    for (const c of calls || []) {
      if (c.name === "clone_agent") {
        cloneCalls.push({ call: c, ownerIndex: partial.index });
      }
    }
  }
  if (cloneCalls.length === 0) return null;

  // Build a map of tool_call_id → result. Results live in
  // tool messages that follow the calling assistant message,
  // but we don't strictly require ordering — index match is
  // enough for the tool-call pairing wire format. Tolerate
  // either snake_case (older wire / DB-restored shapes) or
  // camelCase (in-memory cache shape) keys.
  const resultById = new Map();
  for (const m of messages) {
    const results = m.toolResults || m.tool_results || [];
    for (const r of results || []) {
      const id = r.tool_call_id ?? r.toolCallId;
      if (id) resultById.set(id, r);
    }
  }

  return (
    <div className="mt-2 space-y-2">
      {cloneCalls.map(({ call }) => {
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
              call.arguments?.instruction ?? call.arguments?.instruction ?? ""
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

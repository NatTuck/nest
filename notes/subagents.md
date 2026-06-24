# Sub-Agents and Delegation

## Core Model

Each agent has a `parent_id` (nil for root agents, parent's ID for children). Agents form a tree. The `clone_agent` tool lets a running agent spawn a child with a copy of the current context plus a new instruction. The parent's chat task blocks until the child completes a full turn, then receives the child's final message content as the tool result.

## Architecture Decisions

### Context Inheritance
Child receives the parent's full message history (system prompt + all messages up to the clone point) plus the instruction as a new user message. Future versions may add selective context options.

### Blocking Model
Same pattern as compaction. The parent's chat task sends `{:clone_agent_request, ...}` to the parent GenServer, then blocks on `receive`. The child runs independently. When the child goes idle, its GenServer sends `{:child_completed, child_id, response}` to the parent GenServer, which routes it to the waiting chat task. The parent chat task unblocks and returns the result to the LLM.

### Completion Detection
Child transitions to `:idle` after a full turn (which may include multiple tool-call rounds). At that point, the child's GenServer sends the final assistant message content back to the parent.

### Child Lifecycle
Child stays alive after completing. User can inspect the child's full conversation. Child terminates when parent terminates (cascade). The supervisor tracks parent → children relationships so it can cascade termination.

### Recursion
Children can call `clone_agent` themselves. Depth is tracked on the agent state (`depth: non_neg_integer()`). Configurable max depth, default 3. The tool is only available when `depth < max_depth`.

## Token Tracking — Three Concepts

This is the most complex new design area. We now have three distinct token metrics per agent:

### 1. Context Tokens (per-call)
What the agent sends to the LLM in a single request. This already exists (`context_limit`, `input_tokens` from usage). The child inherits the parent's context, so the child's first call has a large `input_tokens` value. This is already tracked per-call by the LLM provider and reported via `usage.input_tokens`.

### 2. Direct Usage (this agent's own LLM calls)
The sum of all tokens consumed by this agent's own LLM API calls. This is what `usage_totals` already tracks today — it accumulates `input_tokens`, `output_tokens`, `reasoning_tokens` across the agent's lifetime.

**Change**: `usage_totals` becomes explicitly "direct usage" — only this agent's own calls.

### 3. Total Usage (including all descendants)
The sum of this agent's direct usage plus the total usage of all its children, recursively. This is what the user cares about for billing/cost purposes.

**Implementation**: When a child completes, it sends its `total_usage` to the parent. The parent adds the child's total usage to its own running `descendant_usage` accumulator. The parent's `total_usage = direct_usage + descendant_usage`.

### Data Model for Usage

```elixir
defmodule LlmMetrics do
  defstruct context_limit: nil,
            context_limit_source: nil,
            usage_totals: nil,          # Direct usage (this agent's calls)
            descendant_usage: nil       # Sum of all descendants' total usage
            # total_usage = usage_totals + descendant_usage (computed)
end
```

The `descendant_usage` has the same shape as `usage_totals`:
```elixir
%{input_tokens: 0, output_tokens: 0, total_tokens: 0, reasoning_tokens: 0}
```

### Usage Propagation Flow

```
Child completes turn → goes idle
  ↓
Child sends {:child_completed, child_id, response, child_total_usage} to parent
  ↓
Parent GenServer merges child_total_usage into its descendant_usage
  ↓
Parent broadcasts updated total_usage (direct + descendant) via status
  ↓
Chat task unblocks with child's response
```

If the child itself has children, its `total_usage` already includes its descendants, so the merge is just one level up — no recursive walk needed.

### UI Display

Three numbers to show:
- **Context**: `~45k / 128k tokens` (current context window usage — this is per-call, shows what the next LLM call will cost)
- **Direct usage**: `12k tokens out` (this agent's own output tokens)
- **Total usage**: `18k tokens out` (includes 6k from children)

The status broadcast payload extends:
```elixir
%{
  status: "idle",
  contextLimit: 128000,
  usage: %{input_tokens: 45000, output_tokens: 12000, ...},       # direct
  descendantUsage: %{output_tokens: 6000, ...},                    # from children
  totalUsage: %{output_tokens: 18000, ...}                         # computed sum
}
```

## Agent State Changes

```elixir
defstruct [
  :id,
  :parent_id,        # NEW
  :depth,            # NEW (0 for root, parent.depth + 1 for children)
  :model,
  # ... existing fields ...
  chat_state: %{
    # ... existing fields ...
    pending_children: %{}   # NEW: %{child_id => task_pid}
  },
  llm_metrics: %{
    # ... existing fields ...
    descendant_usage: %{...}  # NEW
  }
]
```

## clone_agent Tool

```
Parameters:
  - instruction (string, required): task for the child

Available when: depth < max_depth (default 3)

Result to parent LLM: child's final assistant message content
```

The tool is intercepted by `ToolLoop` (same pattern as `context`). The chat task blocks on `receive` waiting for the result.

## Supervisor Changes

The `DynamicSupervisor` (or a separate tracking module) maintains a parent → children mapping. When an agent is terminated:
1. Look up all children of that agent
2. Terminate each child (which cascades to grandchildren)
3. Then terminate the parent

This can be done via `Process.monitor` — the parent monitors each child, and a separate registry maps parent_id → [child_ids].

## UI Changes

### Agent Tree
The flat agent list becomes a tree. Each agent shows its `parent_id`. Root agents (parent_id = nil) are top-level. Children are nested under their parent. The UI renders this as an indented tree or collapsible tree view.

### Delegated Task Block
In the parent's conversation, where the `clone_agent` tool call appears, render a "Delegated Task" card showing:
- The instruction sent to the child
- The child's ID (clickable link to child's conversation)
- Status indicator (running / completed)
- The child's final response (also shown as the tool result)

### Child's Final Message
When the child completes, its final assistant message shows a "back to parent" link, so users can navigate from child → parent easily.

## Message Flow Summary

```
Parent Agent (chat task running)
  │
  ├─ LLM calls clone_agent(instruction: "do X")
  │
  ├─ ToolLoop intercepts → sends {:clone_agent_request, self(), "do X"} to parent GenServer
  │
  ├─ Chat task blocks on receive
  │
  ├─ Parent GenServer:
  │   ├─ Calls Supervisor.start_agent_with_parent(parent_attrs, child_attrs)
  │   ├─ Child agent starts (depth = parent.depth + 1)
  │   ├─ Sends instruction as user message to child via Agents.chat(child_id, instruction)
  │   ├─ Stores {child_id => task_pid} in pending_children
  │   └─ Sends {:clone_agent_started, child_id} to chat task
  │
  ├─ Child agent runs full turn (may call tools, may recurse)
  │
  ├─ Child goes idle → sends {:child_completed, child_id, response, child_total_usage} to parent
  │
  ├─ Parent GenServer:
  │   ├─ Merges child_total_usage into descendant_usage
  │   ├─ Removes child_id from pending_children
  │   ├─ Sends {:clone_agent_result, child_id, response} to waiting chat task
  │   └─ Broadcasts updated status (with total_usage)
  │
  ├─ Chat task unblocks → returns response as tool result
  │
  └─ Parent LLM continues with next tool call or final response
```

## Open Implementation Questions

1. **Max depth config**: Where does the configurable max depth live? DotConfig (like `max-tool-iterations`) seems natural. Default 3.

Lives in DotConfig.

2. **Child visible in agent list**: The agent list API needs to return `parent_id` and `depth` so the UI can build the tree. The `get_public_info/1` and `list_agents_info/0` functions need to include these fields.

3. **Cascade termination**: Simplest approach is the parent GenServer's `terminate/2` callback looks up its children and stops them. But we need to handle the case where a child is mid-chat when the parent dies — the child's chat task will continue until it naturally completes or errors. Should we forcefully kill children, or let them finish?

The parent should clean up its children all the way.

4. **Stopping a parent while waiting**: If the user clicks Stop on the parent while it's blocked waiting for a child, the `{:stop_chat, from}` signal propagates to the chat task (which is blocked on receive). The chat task catches it and returns `:stopped`. The child continues running independently — should it? Or should stopping the parent also stop the child?

Stopping the parent should also stop the child.

5. **Tool availability for children**: Children get the same tools as the parent (inherited via vocation), minus `clone_agent` if they're at max depth. The tool list is built at agent creation time, so we need to check depth when building the tool list.

Yes.

6. **Usage at child completion**: The child needs to send its `total_usage` (direct + descendant) at completion time. This means `get_public_info` or a new `get_total_usage` function needs to be called by the child's GenServer before sending the completion message.

Yes.

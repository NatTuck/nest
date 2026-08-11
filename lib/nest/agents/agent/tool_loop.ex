defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by `Nest.Agents.Agent.ChatTurn` after a response
  with `tool_calls` is received. Responsibilities:

    * Split the batch by tool — `clone_agent` is routed
      through `run_clone_agent/2` (synchronous parent →
      spawn → wait → synthetic ToolResult); everything else
      is delegated to `Nest.Agents.Agent.BatchSizer`.
    * Merge the two halves back into input order.

  `context.compact` is no longer routed through this module —
  the chat turn's response handler detects it ahead of the
  tool worker and exits with a `{:compact_tool, _, _, _}`
  continuation. The blocked-tool-worker pattern (where the
  tool worker awaited the compactor on receive) is gone.
  `context_compact?/1` and `strip_context_compact/1` are
  retained for compatibility with `BatchSizer.preflight/2`,
  which strips `context.compact` from its preflight input so
  BatchSizer doesn't try to project a per-tool size for it.
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Registry
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  require Logger

  # Generous default — most sub-agent turns finish in
  # seconds; this protects the worker's `receive` from
  # hanging forever if a child's chat task wedges.
  @clone_agent_wait_ms 120_000

  # Cap for the `list_agents` tool result. A space with many
  # agents could produce a huge serialized list; truncating
  # keeps the tool output within a reasonable context cost.
  @list_agents_max_chars 4_000

  # `query_agent` blocks the tool worker until the target goes
  # idle. The receive loop polls in slices and gives up after
  # `@query_agent_wait_ms` total. The slice keeps the loop
  # responsive to late-arriving idle broadcasts and lets us
  # bound the total wait without a deadline computation.
  @query_agent_wait_ms 60_000
  @query_agent_slice_ms 250
  @query_agent_attempts div(@query_agent_wait_ms, @query_agent_slice_ms)

  @doc """
  Run a tool-call batch. Returns a list of `ToolResult`
  structs in input order.

  The `state` argument is unused; kept in the signature for
  symmetry with the call site.
  """
  @spec execute(map(), term(), [ToolCall.t()]) :: [ToolResult.t()]
  def execute(ctx, _state, tool_calls) do
    case tool_calls do
      [] -> []
      calls -> run_batch(ctx, calls)
    end
  end

  @doc """
  Returns true if `tool_call` is a `context.compact` invocation.
  Exposed for `BatchSizer.preflight/2` callers that need to
  strip `context.compact` from their preflight input.
  """
  @spec context_compact?(ToolCall.t()) :: boolean()
  def context_compact?(%ToolCall{name: "context", arguments: %{"action" => "compact"}}),
    do: true

  def context_compact?(_), do: false

  @doc """
  Strip `context.compact` calls out of a tool-call list.
  Returns every other call unchanged.
  """
  @spec strip_context_compact([ToolCall.t()]) :: [ToolCall.t()]
  def strip_context_compact(tool_calls) do
    Enum.reject(tool_calls, &context_compact?/1)
  end

  # Private — batch dispatch.

  # Split the tool-call batch by tool family and route
  # each half to its executor. Re-merge into input order
  # so the chat turn's `{:tool, _}` message carries
  # `ToolResult` parts in the same order as the LLM's
  # `tool_use` parts.
  #
  # Sub-agent tool families are split out of the regular batch:
  # `clone_agent` (synchronous spawn + wait), `spawn_agent`
  # (synchronous spawn, no wait), and `list_agents` (inline
  # read). Everything else is delegated to `BatchSizer`.
  defp run_batch(ctx, calls) do
    {sub_calls, regular_calls} = Enum.split_with(calls, &sub_agent_tool?/1)

    regular_results =
      if regular_calls == [],
        do: %{},
        else: BatchSizer.run(regular_calls, ctx) |> Map.new(fn tr -> {tr.tool_call_id, tr} end)

    sub_results =
      Enum.map(sub_calls, fn tc -> {tc.id, run_sub_agent_tool(ctx, tc)} end)
      |> Map.new()

    Enum.map(calls, fn %ToolCall{id: id} ->
      Map.fetch!(regular_results |> Map.merge(sub_results), id)
    end)
  end

  defp sub_agent_tool?(%ToolCall{name: name})
       when name in ["clone_agent", "spawn_agent", "list_agents", "query_agent"],
       do: true

  defp sub_agent_tool?(_), do: false

  defp run_sub_agent_tool(ctx, %ToolCall{name: "clone_agent"} = tc), do: run_clone_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "spawn_agent"} = tc), do: run_spawn_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "list_agents"} = tc), do: run_list_agents(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "query_agent"} = tc), do: run_query_agent(ctx, tc)

  # `spawn_agent`: ask the coordinator GenServer to spawn an
  # independent, fresh-context specialist (whitelist-checked by
  # `Supervisor.spawn_agent_in_space/3`) and return its name.
  defp run_spawn_agent(ctx, %ToolCall{} = tc) do
    name = extract_string_arg(tc, "name")
    vocation_id = extract_int_arg(tc, "vocation_id")

    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:spawn_agent_request, self(), name, vocation_id}) do
      {:ok, spawned_name} ->
        build_tool_result(tc, "spawn_agent", "Spawned agent #{spawned_name}.")

      {:error, reason} ->
        build_tool_result(
          tc,
          "spawn_agent",
          "Could not spawn agent: #{inspect(reason)}",
          true
        )
    end
  end

  # `list_agents`: read the space's live agents and serialize
  # their name, vocation, status, and depth. Pure read — no
  # GenServer round-trip needed.
  defp run_list_agents(ctx, %ToolCall{} = tc) do
    listing =
      Nest.Agents.list_agents_info_for_space(ctx.space_id)
      |> Enum.map(fn info ->
        %{
          name: info.name,
          vocation_id: info.vocation_id,
          status: info.status,
          depth: info.depth
        }
      end)

    content =
      if listing == [] do
        "No agents in this space."
      else
        listing |> inspect() |> String.slice(0, @list_agents_max_chars)
      end

    build_tool_result(tc, "list_agents", content)
  end

  # `query_agent`: send a chat message to a PEER agent in this
  # space and block until its turn goes idle, returning the
  # target's final assistant text as the tool result.
  #
  # Unlike `clone_agent` (a child the parent tracks in
  # `pending_children`), the queried agent is independent and
  # has no relationship to the caller, so there is no
  # `:child_completed` cast to wait on. Instead we subscribe to
  # the target's PubSub topic, trigger its turn with
  # `Agents.chat/3`, and watch for the idle `:chat_status`
  # broadcast. We capture the target's message count BEFORE
  # sending so the first idle we see is only accepted once a
  # NEW assistant message (index >= pre_count) exists — this
  # guards against reading a stale, pre-query response.
  defp run_query_agent(ctx, %ToolCall{} = tc) do
    target = extract_string_arg(tc, "name")
    prompt = extract_string_arg(tc, "prompt")

    case Nest.Agents.get_messages(ctx.space_id, target) do
      {:ok, messages} ->
        topic = "agent:#{ctx.space_id}:#{target}"
        Phoenix.PubSub.subscribe(Nest.PubSub, topic)

        try do
          case Nest.Agents.chat(ctx.space_id, target, prompt) do
            :ok ->
              content = await_query_result(ctx.space_id, target, length(messages))
              build_tool_result(tc, "query_agent", content)

            {:error, reason} ->
              build_tool_result(
                tc,
                "query_agent",
                "Could not query #{target}: #{inspect(reason)}",
                true
              )
          end
        after
          Phoenix.PubSub.unsubscribe(Nest.PubSub, topic)
        end

      {:error, reason} ->
        build_tool_result(
          tc,
          "query_agent",
          "Agent #{target} not found in this space: #{inspect(reason)}",
          true
        )
    end
  end

  defp await_query_result(space_id, target, pre_count) do
    wait_for_idle(space_id, target, pre_count, 0)
  end

  defp wait_for_idle(_space_id, _target, _pre_count, attempts)
       when attempts >= @query_agent_attempts do
    Logger.warning("query_agent: target did not go idle within #{@query_agent_wait_ms}ms")
    ""
  end

  defp wait_for_idle(space_id, target, pre_count, attempts) do
    receive do
      {:chat_status, %{status: "idle"}} ->
        case read_last_assistant_after(space_id, target, pre_count) do
          nil -> wait_for_idle(space_id, target, pre_count, attempts + 1)
          content -> content
        end

      _other ->
        wait_for_idle(space_id, target, pre_count, attempts + 1)
    after
      @query_agent_slice_ms ->
        wait_for_idle(space_id, target, pre_count, attempts + 1)
    end
  end

  # The target's newest assistant message that arrived after the
  # query was sent (index >= pre_count). Returns `nil` when the
  # turn hasn't produced one yet (so the idle wait keeps going).
  defp read_last_assistant_after(space_id, target, pre_count) do
    case Nest.Agents.get_messages(space_id, target) do
      {:ok, messages} ->
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          {:assistant, %{index: idx, parts: parts}} when idx >= pre_count ->
            assistant_text(parts)

          _ ->
            nil
        end)

      {:error, _} ->
        nil
    end
  end

  defp assistant_text(parts) do
    Enum.map_join(parts, fn
      %Part.Text{text: text} -> text
      _ -> ""
    end)
  end

  # Synchronous clone path. Sends a `{:clone_agent_request,
  # task_pid, instruction}` to the parent GenServer and
  # blocks on its reply, then awaits the eventual
  # `:clone_agent_result` forwarded from the parent when
  # the child finishes its turn. Returns a single
  # `ToolResult` carrying the child's final assistant
  # content (or an error string on timeout).
  defp run_clone_agent(ctx, %ToolCall{} = tc) do
    instruction = extract_instruction(tc)
    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:clone_agent_request, self(), instruction}) do
      {:ok, child_name} ->
        receive do
          {:clone_agent_result, ^child_name, response} ->
            build_clone_result(tc, response, false)
        after
          @clone_agent_wait_ms ->
            Logger.warning(
              "clone_agent: child #{child_name} did not complete within #{@clone_agent_wait_ms}ms"
            )

            build_clone_result(tc, "Child agent did not complete in time.", true)
        end

      {:error, reason} ->
        build_clone_result(tc, "Could not spawn child agent: #{inspect(reason)}", true)
    end
  end

  defp extract_instruction(%ToolCall{arguments: %{"instruction" => i}}) when is_binary(i), do: i

  defp extract_instruction(_), do: ""

  defp extract_string_arg(%ToolCall{arguments: args}, key) when is_map(args) do
    case Map.get(args, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp extract_string_arg(_tc, _key), do: ""

  defp extract_int_arg(%ToolCall{arguments: args}, key) when is_map(args) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp extract_int_arg(_tc, _key), do: nil

  defp build_clone_result(%ToolCall{} = tc, content, is_error) do
    build_tool_result(tc, "clone_agent", content, is_error)
  end

  defp build_tool_result(%ToolCall{} = tc, name, content, is_error \\ false) do
    %ToolResult{
      tool_call_id: tc.id,
      name: name,
      arguments: tc.arguments,
      content: content,
      is_error: is_error
    }
  end
end

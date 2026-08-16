defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by `Nest.Agents.Agent.ChatTurn` after a response
  with `tool_calls` is received. Responsibilities:

    * Split the batch by tool — sub-agent tools (`agents-spawn`,
      `agents-query`, `agents-list`, `agents-archive`) are routed
      through their `run_*` handlers (synchronous spawn/query/
      archive through the agent GenServer; `agents-list` reads the
      space inline); everything else is delegated to
      `Nest.Agents.Agent.BatchSizer`.
    * Merge the two halves back into input order.

  `context-compact` is no longer routed through this module —
  the chat turn's response handler detects it ahead of the
  tool worker and exits with a `{:compact_tool, _, _, _}`
  continuation. The blocked-tool-worker pattern (where the
  tool worker awaited the compactor on receive) is gone.
  `context_compact?/1` and `strip_context_compact/1` are
  retained for compatibility with `BatchSizer.preflight/2`,
  which strips `context-compact` from its preflight input so
  BatchSizer doesn't try to project a per-tool size for it.
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Registry
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  require Logger

  # Default cap for blocking sub-agent waits (`agents-spawn`
  # with a `query`, and `agents-query`). Agent work can be
  # slow, so this is generous (5 minutes). Both tools accept a
  # `timeout` argument to override it. The 250ms slice keeps
  # the poll loop responsive to late-arriving broadcasts.
  @default_wait_ms 300_000
  @wait_slice_ms 250

  # Cap for the `agents-list` tool result. A space with many
  # agents could produce a huge serialized list; truncating
  # keeps the tool output within a reasonable context cost.
  @list_agents_max_chars 4_000

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
  Returns true if `tool_call` is a `context-compact` invocation.
  Exposed for `BatchSizer.preflight/2` callers that need to
  strip `context-compact` from their preflight input.
  """
  @spec context_compact?(ToolCall.t()) :: boolean()
  def context_compact?(%ToolCall{name: "context-compact"}), do: true

  def context_compact?(_), do: false

  @doc """
  Strip `context-compact` calls out of a tool-call list.
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
  # `agents-spawn` (synchronous spawn, optional query-wait +
  # archive), `agents-query` (block on a peer), `agents-list`
  # (inline read), and `agents-archive` (stop + mark archived).
  # Everything else is delegated to `BatchSizer`.
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
       when name in ["agents-spawn", "agents-query", "agents-list", "agents-archive"],
       do: true

  defp sub_agent_tool?(_), do: false

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-spawn"} = tc), do: run_spawn_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-query"} = tc), do: run_query_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-list"} = tc), do: run_list_agents(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-archive"} = tc),
    do: run_archive_agent(ctx, tc)

  # `agents-spawn`: the general sub-agent spawn API. Unifies the
  # old `clone_agent` (via `clone_context`) and `spawn_agent`.
  # Ask the coordinator GenServer to spawn a child (fresh or
  # context-cloned), optionally send it a `query` and block for
  # the response, and optionally `archive` it afterward.
  defp run_spawn_agent(ctx, %ToolCall{} = tc) do
    opts = spawn_opts_from_args(tc)
    query = opts.query
    timeout = opts.timeout

    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:spawn_agent_request, self(), opts}, timeout) do
      {:ok, spawned_name} ->
        if query == "" do
          build_tool_result(tc, "agents-spawn", "Spawned agent #{spawned_name}.")
        else
          await_spawn_result(tc, spawned_name, timeout)
        end

      {:error, reason} ->
        build_tool_result(
          tc,
          "agents-spawn",
          "Could not spawn agent: #{inspect(reason)}",
          true
        )
    end
  end

  # Extract the `agents-spawn` args into an opts map, applying
  # defaults. Kept separate so `run_spawn_agent/2` stays under
  # the credo ABC cap.
  defp spawn_opts_from_args(tc) do
    %{
      name: extract_string_arg(tc, "name"),
      vocation_id: extract_int_arg(tc, "vocation_id"),
      clone_context: extract_bool_arg(tc, "clone_context", false),
      query: extract_string_arg(tc, "query"),
      archive: extract_bool_arg(tc, "archive", false),
      timeout: extract_int_arg(tc, "timeout") || @default_wait_ms
    }
  end

  # After a successful spawn with a `query`, block until the
  # child completes (or times out), returning the child's final
  # response as the tool result.
  defp await_spawn_result(tc, spawned_name, timeout) do
    receive do
      {:spawn_agent_result, ^spawned_name, response} ->
        build_tool_result(tc, "agents-spawn", response)

      {:spawn_agent_error, ^spawned_name, reason} ->
        build_tool_result(
          tc,
          "agents-spawn",
          "Child agent #{spawned_name} failed: #{inspect(reason)}",
          true
        )
    after
      timeout ->
        Logger.warning("agents-spawn: child #{spawned_name} did not complete within #{timeout}ms")

        build_tool_result(tc, "agents-spawn", "Child agent did not complete in time.", true)
    end
  end

  # `agents-list`: read the space's live agents and serialize
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

    build_tool_result(tc, "agents-list", content)
  end

  # `agents-query`: send a chat message to a PEER agent in this
  # space and block until its turn goes idle, returning the
  # target's final assistant text as the tool result.
  #
  # Unlike `agents-spawn` (a child the parent tracks in
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
    timeout = extract_int_arg(tc, "timeout") || @default_wait_ms

    query_peer(ctx.space_id, target, prompt, timeout)
    |> build_query_result(tc, target)
  end

  # Send a chat to a peer and block for its response. Returns
  # `{:ok, content}` or `{:error, reason}`. Kept separate so
  # `run_query_agent/2` stays under the credo ABC cap.
  defp query_peer(space_id, target, prompt, timeout) do
    case Nest.Agents.get_messages(space_id, target) do
      {:ok, messages} ->
        topic = "agent:#{space_id}:#{target}"
        Phoenix.PubSub.subscribe(Nest.PubSub, topic)

        try do
          case Nest.Agents.chat(space_id, target, prompt) do
            :ok -> {:ok, await_query_result(space_id, target, length(messages), timeout)}
            {:error, reason} -> {:error, {:chat, reason}}
          end
        after
          Phoenix.PubSub.unsubscribe(Nest.PubSub, topic)
        end

      {:error, reason} ->
        {:error, {:not_found, reason}}
    end
  end

  defp build_query_result({:ok, content}, tc, _target),
    do: build_tool_result(tc, "agents-query", content)

  defp build_query_result({:error, {:chat, reason}}, tc, target),
    do:
      build_tool_result(tc, "agents-query", "Could not query #{target}: #{inspect(reason)}", true)

  defp build_query_result({:error, {:not_found, reason}}, tc, target),
    do:
      build_tool_result(
        tc,
        "agents-query",
        "Agent #{target} not found in this space: #{inspect(reason)}",
        true
      )

  # `agents-archive`: stop + mark an existing agent in this
  # space archived. Routes through the parent GenServer so the
  # stop/DB write happens in the same process context as other
  # lifecycle operations.
  defp run_archive_agent(ctx, %ToolCall{} = tc) do
    target = extract_string_arg(tc, "name")
    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:archive_agent_request, self(), target}) do
      {:ok, archived_name} ->
        build_tool_result(tc, "agents-archive", "Archived agent #{archived_name}.")

      {:error, reason} ->
        build_tool_result(
          tc,
          "agents-archive",
          "Could not archive #{target}: #{inspect(reason)}",
          true
        )
    end
  end

  defp await_query_result(space_id, target, pre_count, timeout) do
    attempts = div(timeout, @wait_slice_ms)
    wait_for_idle(space_id, target, pre_count, 0, attempts, timeout)
  end

  defp wait_for_idle(_space_id, _target, _pre_count, attempts, attempts, timeout) do
    Logger.warning("agents-query: target did not go idle within #{timeout}ms")
    ""
  end

  defp wait_for_idle(space_id, target, pre_count, attempts, max_attempts, timeout) do
    receive do
      {:chat_status, %{status: "idle"}} ->
        case read_last_assistant_after(space_id, target, pre_count) do
          nil -> wait_for_idle(space_id, target, pre_count, attempts + 1, max_attempts, timeout)
          content -> content
        end

      _other ->
        wait_for_idle(space_id, target, pre_count, attempts + 1, max_attempts, timeout)
    after
      @wait_slice_ms ->
        wait_for_idle(space_id, target, pre_count, attempts + 1, max_attempts, timeout)
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

  defp extract_bool_arg(%ToolCall{arguments: args}, key, default) when is_map(args) do
    case Map.get(args, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp extract_bool_arg(_tc, _key, default), do: default

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

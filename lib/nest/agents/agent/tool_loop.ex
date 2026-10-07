defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by the in-process turn (`Nest.Agents.Agent.Turn`) after a
  response with `tool_calls` is received. Responsibilities:

    * Split the batch by tool — sub-agent tools (`agents-spawn`,
      `agents-query`, `agents-send`, `agents-wait`, `agents-list`,
      `agents-archive`, `agents-batch`, `models-list`) are routed
      through their `run_*` handlers, which run in this worker and
      never in the agent GenServer; everything else is delegated to
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

  alias Nest.Agents.Agent.AsyncWaiter
  alias Nest.Agents.Agent.BatchLoop
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.PeerQuery
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Agents.Agent.WaitLoop
  alias Nest.Agents.Registry
  alias Nest.DotConfig
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Models

  require Logger

  # Default cap for blocking sub-agent waits (`agents-spawn`
  # with a `query`, and `agents-query`), and for the async waiters
  # those tools start. Agent work can be slow, so this is generous
  # (5 minutes). Both tools accept a `timeout` argument to override
  # it.
  @default_wait_ms 300_000

  # Cap for the `agents-list` tool result. A space with many
  # agents could produce a huge serialized list; truncating
  # keeps the tool output within a reasonable context cost.
  @list_agents_max_chars 4_000

  # Cap for the `models-list` tool result. A provider set with
  # many models could produce a large serialized list; truncating
  # keeps the tool output within a reasonable context cost.
  @list_models_max_chars 4_000

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
  # archive, or `async` to hand the wait to a waiter),
  # `agents-query` (block on a peer, or `async`), `agents-list`
  # (inline read), and `agents-archive` (stop + mark archived).
  # Everything else is delegated to `BatchSizer`.
  defp run_batch(ctx, calls) do
    {sub_calls, regular_calls} = Enum.split_with(calls, &sub_agent_tool?/1)

    regular_entries = BatchSizer.execute(regular_calls, ctx)

    sub_entries =
      Enum.map(sub_calls, fn tc ->
        %ToolResult{content: content, is_error: is_error} = run_sub_agent_tool(ctx, tc)
        {tc, if(is_error, do: :error, else: :ok), content}
      end)

    # One authoritative budget pass over the whole batch so regular and
    # sub-agent results share a single running total. Without this a mixed
    # batch could exceed the context window even though each half fits.
    by_id =
      (regular_entries ++ sub_entries)
      |> Map.new(fn {tc, kind, content} -> {tc.id, {tc, kind, content}} end)

    entries = Enum.map(calls, fn tc -> Map.fetch!(by_id, tc.id) end)

    BatchSizer.cook(entries, ctx)
  end

  defp sub_agent_tool?(%ToolCall{name: name})
       when name in [
              "agents-spawn",
              "agents-query",
              "agents-list",
              "agents-archive",
              "agents-batch",
              "agents-send",
              "agents-wait",
              "models-list"
            ],
       do: true

  defp sub_agent_tool?(_), do: false

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-spawn"} = tc), do: run_spawn_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-query"} = tc), do: run_query_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-send"} = tc), do: run_send_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-wait"} = tc), do: run_wait_agents(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-list"} = tc), do: run_list_agents(ctx, tc)
  defp run_sub_agent_tool(_ctx, %ToolCall{name: "models-list"} = tc), do: run_models_list(tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-batch"} = tc),
    do: run_agents_batch(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-archive"} = tc),
    do: run_archive_agent(ctx, tc)

  # `agents-spawn`: the general sub-agent spawn API. Unifies the
  # old `clone_agent` (via `clone_context`) and `spawn_agent`.
  # Ask the coordinator GenServer to spawn a child (fresh or
  # context-cloned), optionally send it a `query` and block for
  # the response, and optionally `archive` it afterward. With
  # `async: true` (and a `query`) the wait is handed to a
  # supervised waiter and the response arrives later as a message.
  defp run_spawn_agent(ctx, %ToolCall{} = tc) do
    opts = spawn_opts_from_args(tc)

    if extract_bool_arg(tc, "async", false) and opts.query != "" do
      run_spawn_async(ctx, tc, opts)
    else
      run_spawn_blocking(ctx, tc, opts)
    end
  end

  # The default path: this worker owns the blocking wait.
  defp run_spawn_blocking(ctx, tc, opts) do
    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:spawn_agent_request, self(), opts}, opts.timeout) do
      {:ok, spawned_name} ->
        if opts.query == "" do
          build_tool_result(tc, "agents-spawn", "Spawned agent #{spawned_name}.")
        else
          await_spawn_result(ctx, tc, spawned_name, opts.timeout)
        end

      {:error, reason} ->
        build_tool_result(tc, "agents-spawn", spawn_error_message(reason), true)
    end
  end

  # The async path: start the supervised waiter first (so an early
  # completion can never be forwarded to a not-yet-existing process),
  # then do the spawn call synchronously so a bad spawn still comes
  # back to the model as an immediate error it can fix. On success the
  # worker returns the confirmation and the waiter owns the receive;
  # on failure the worker abandons the waiter so it cannot wait out its
  # timeout.
  defp run_spawn_async(ctx, tc, opts) do
    case AsyncWaiter.start_spawn(ctx.agent_pid, ctx, tc, opts.timeout) do
      {:ok, waiter} -> await_spawn_async(ctx, tc, opts, waiter)
      {:error, reason} -> build_tool_result(tc, "agents-spawn", waiter_start_error(reason), true)
    end
  end

  defp await_spawn_async(ctx, tc, opts, waiter) do
    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:spawn_agent_request, waiter, opts}, opts.timeout) do
      {:ok, spawned_name} ->
        send(waiter, {:spawn_agent_go, spawned_name})
        build_tool_result(tc, "agents-spawn", spawn_async_confirmation(spawned_name))

      {:error, reason} ->
        send(waiter, :spawn_agent_abandon)
        build_tool_result(tc, "agents-spawn", spawn_error_message(reason), true)
    end
  end

  defp spawn_async_confirmation(spawned_name) do
    "Spawned agent #{spawned_name} asynchronously. Its response will arrive " <>
      "later as a message in your inbox; use `agents-wait` to wait for it."
  end

  defp waiter_start_error(reason),
    do: "Could not start the async waiter: #{inspect(reason)}"

  # Format a spawn failure for the model. `:vocation_not_spawnable`
  # carries the whitelisted `{name, slug}` vocations so the model can
  # retry with a valid `vocation` slug.
  defp spawn_error_message({:vocation_not_spawnable, allowed}) do
    labels = Enum.map_join(allowed, ", ", fn {name, slug} -> "#{name} (#{slug})" end)

    "Could not spawn agent: that vocation is not spawnable in this space. " <>
      "Allowed vocations: #{labels}. Retry passing one as `vocation`."
  end

  defp spawn_error_message({:vocation_not_found, slug}) do
    "Could not spawn agent: no vocation with slug #{inspect(slug)} exists. " <>
      "Retry with a valid `vocation` slug."
  end

  defp spawn_error_message(reason), do: "Could not spawn agent: #{inspect(reason)}"

  # Extract the `agents-spawn` args into an opts map, applying
  # defaults. Kept separate so `run_spawn_agent/2` stays under
  # the credo ABC cap.
  defp spawn_opts_from_args(tc) do
    %{
      name: extract_string_arg(tc, "name"),
      vocation: extract_string_arg(tc, "vocation"),
      clone_context: extract_bool_arg(tc, "clone_context", false),
      model: extract_string_arg(tc, "model"),
      query: extract_string_arg(tc, "query"),
      archive: extract_bool_arg(tc, "archive", false),
      timeout: extract_int_arg(tc, "timeout") || @default_wait_ms
    }
  end

  # After a successful spawn with a `query`, block until the
  # child completes (or times out), returning the child's final
  # response as the tool result.
  defp await_spawn_result(ctx, tc, spawned_name, timeout) do
    receive do
      {:spawn_agent_result, ^spawned_name, response} ->
        build_tool_result(
          tc,
          "agents-spawn",
          SubAgentResults.spawn_completed(ctx, tc, spawned_name, response),
          response == ""
        )

      {:spawn_agent_error, ^spawned_name, reason} ->
        build_tool_result(
          tc,
          "agents-spawn",
          SubAgentResults.spawn_child_failed(spawned_name, reason),
          true
        )
    after
      timeout ->
        Logger.warning("agents-spawn: child #{spawned_name} did not complete within #{timeout}ms")

        build_tool_result(tc, "agents-spawn", SubAgentResults.spawn_timeout(), true)
    end
  end

  # `agents-list`: read the space's non-archived agents —
  # running or persisted-only — and serialize their name,
  # vocation, status, and depth. Pure read — no GenServer
  # round-trip needed.
  defp run_list_agents(ctx, %ToolCall{} = tc) do
    listing =
      Nest.Agents.list_agents_info_for_space(ctx.space_id)
      |> Enum.map(fn info ->
        %{
          name: info.name,
          # Every listing entry carries a resolved slug: the
          # registry branch from the live agent's vocation struct,
          # the persisted-only branch resolved from the row's
          # `vocation_id` by `Nest.Agents.Visibility`.
          vocation: Map.get(info, :vocation_slug),
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

  # `models-list`: list models from providers configured with
  # `expose_models: true`. The optional `provider` argument
  # narrows the listing to a single provider. Read-only and
  # inline (no GenServer round-trip), like `agents-list`.
  defp run_models_list(%ToolCall{} = tc) do
    provider = extract_string_arg(tc, "provider")
    content = models_listing(provider)
    build_tool_result(tc, "models-list", content)
  end

  # Compose the models-listing text. Returns a friendly message
  # when no provider exposes its models or nothing matches the
  # (optional) provider filter.
  defp models_listing(provider) do
    case exposed_provider_names() do
      [] ->
        "No models are listed: no configured provider has expose-models enabled."

      exposed ->
        lines =
          Models.list()
          |> Enum.filter(&model_exposed?(&1, exposed, provider))
          |> Enum.map(&format_model_entry/1)

        case lines do
          [] -> "No models match the request."
          _ -> lines |> Enum.join("\n") |> String.slice(0, @list_models_max_chars)
        end
    end
  end

  # The provider names configured with `expose_models: true`.
  defp exposed_provider_names do
    case DotConfig.load() do
      {:ok, config} ->
        config.providers
        |> Map.values()
        |> Enum.filter(& &1.expose_models)
        |> Enum.map(& &1.name)

      _ ->
        []
    end
  end

  # A model entry qualifies when its provider exposes models (and,
  # when a filter is given, matches it). Entries without a provider
  # never qualify — the expose flag lives on the provider.
  defp model_exposed?(%{"provider" => p}, exposed, provider_filter) when is_binary(p) do
    p in exposed and (provider_filter == "" or p == provider_filter)
  end

  defp model_exposed?(%{}, _exposed, _provider_filter), do: false

  defp format_model_entry(%{"provider" => provider, "name" => name}),
    do: "#{provider}/#{name}"

  # `agents-query`: send a chat message to a PEER agent in this
  # space and block until its turn goes idle, returning the
  # target's final assistant text as the tool result.
  #
  # The wait itself lives in `Nest.Agents.Agent.PeerQuery` (shared with
  # the async waiter). The wait is tagged: a timeout, a failed read, or
  # a turn that finished without text all come back as errors with
  # distinct messages, never as a successful empty result. With
  # `async: true` the waiter owns the wait and delivers the same content
  # later as a message.
  defp run_query_agent(ctx, %ToolCall{} = tc) do
    target = extract_string_arg(tc, "name")
    prompt = extract_string_arg(tc, "prompt")
    timeout = extract_int_arg(tc, "timeout") || @default_wait_ms

    if extract_bool_arg(tc, "async", false) do
      run_query_async(ctx, tc, target, prompt, timeout)
    else
      PeerQuery.run(ctx.space_id, target, prompt, timeout)
      |> build_query_result(tc, target, ctx)
    end
  end

  # The async path: the waiter owns the whole query (subscribe, chat,
  # wait for idle, read the reply) and delivers the same content the
  # blocking path would have returned as a tool result.
  defp run_query_async(ctx, tc, target, prompt, timeout) do
    case AsyncWaiter.start_query(ctx.agent_pid, ctx, tc, target, prompt, timeout) do
      {:ok, _waiter} -> build_tool_result(tc, "agents-query", query_async_confirmation(target))
      {:error, reason} -> build_tool_result(tc, "agents-query", waiter_start_error(reason), true)
    end
  end

  defp query_async_confirmation(target) do
    "Querying #{target} asynchronously. Its response will arrive later as a " <>
      "message in your inbox; use `agents-wait` to wait for it."
  end

  defp build_query_result({:ok, content}, tc, _target, ctx),
    do: build_tool_result(tc, "agents-query", SubAgentResults.query_success(ctx, tc, content))

  defp build_query_result({:error, reason}, tc, target, _ctx),
    do: build_tool_result(tc, "agents-query", SubAgentResults.query_failure(reason, target), true)

  # `agents-send`: asynchronously deliver a message to another agent in
  # this space. Unlike `agents-query`, it never waits for a turn: the
  # target either starts one (idle) or queues the message (busy). The
  # call goes straight to the target's GenServer so two agents messaging
  # each other cannot deadlock through the sender's mailbox.
  defp run_send_agent(ctx, %ToolCall{} = tc) do
    target = extract_string_arg(tc, "name")
    message = extract_string_arg(tc, "message")

    cond do
      target == "" ->
        build_tool_result(tc, "agents-send", "Missing required argument: name.", true)

      message == "" ->
        build_tool_result(tc, "agents-send", "Missing required argument: message.", true)

      true ->
        deliver_to_target(ctx, tc, target, message)
    end
  end

  defp deliver_to_target(ctx, tc, target, message) do
    case Nest.Agents.send_message(ctx.space_id, ctx.agent_name, target, message) do
      {:ok, :delivered} ->
        build_tool_result(tc, "agents-send", "Message delivered to #{target}.")

      {:ok, :queued} ->
        build_tool_result(tc, "agents-send", "Message queued for #{target} (busy).")

      {:error, :not_found} ->
        build_tool_result(tc, "agents-send", "Agent #{target} not found in this space.", true)

      {:error, reason} ->
        build_tool_result(tc, "agents-send", send_error_message(target, reason), true)
    end
  end

  defp send_error_message(target, :inbox_full) do
    "Could not send to #{target}: its inbox is full."
  end

  defp send_error_message(target, {:status, status}) do
    "Could not send to #{target}: it is in a #{status} state."
  end

  defp send_error_message(target, reason), do: "Could not send to #{target}: #{inspect(reason)}"

  # `agents-wait`: block in this worker until one of the target agents
  # goes idle (or the wall-clock `timeout` expires), then report that
  # agent and its stop message. The wait lives in `WaitLoop` so the
  # agent GenServer is never blocked by it.
  defp run_wait_agents(ctx, %ToolCall{} = tc) do
    case WaitLoop.run(ctx, tc) do
      {:ok, content} ->
        build_tool_result(tc, "agents-wait", SubAgentResults.bound(content, tc, ctx))

      {:error, content} ->
        build_tool_result(tc, "agents-wait", content, true)
    end
  end

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

  # `agents-batch`: fan ONE templated instruction out over a set of
  # items to concurrent sub-agents and get back a single JSON aggregate
  # (each child's final response, in item order). Runs synchronously in
  # this (separate-process) tool worker; the coordinator stays free to
  # service the children's completions while we block. Whole-call
  # failures surface as `is_error: true`; per-item failures/timeout are
  # collected as marker slots inside the aggregate.
  defp run_agents_batch(ctx, %ToolCall{} = tc) do
    case BatchLoop.run(ctx, tc) do
      {:ok, content} -> build_tool_result(tc, "agents-batch", content)
      {:error, reason} -> build_tool_result(tc, "agents-batch", reason, true)
    end
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

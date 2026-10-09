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

  alias Nest.Agents.Agent.BatchCoordinator
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Agents.Agent.WaitLoop
  alias Nest.Agents.Registry
  alias Nest.DotConfig
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Models

  # How long the spawn *request* itself may take: it creates the child process
  # and its rows, and delivers the query — it is not a wait for the child's
  # answer, which never blocks this worker. Generous because it is a GenServer
  # call into the parent, which serializes it against the parent's other work.
  @spawn_request_timeout 30_000

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
  # `agents-spawn` (spawn, deliver the query, and return — nothing waits),
  # `agents-query` (deliver, and mark the reply owed), `agents-list`
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

  # `agents-spawn`: the general sub-agent spawn API. Unifies the old
  # `clone_agent` (via `clone_context`) and `spawn_agent`: ask the parent
  # GenServer to spawn a child (fresh or context-cloned) and optionally deliver
  # a `query` to it.
  #
  # Nothing waits (decision 2, always async): the child's answer arrives later as
  # a message in this agent's own inbox, through the parent's §2.1 delivery — the
  # child's own words when it produced content, a runtime notice naming the
  # reason when it failed, was stopped, or produced nothing. The call itself only
  # waits for the *spawn* to be decided, so a bad spawn still comes back to the
  # model as an immediate error it can fix.
  defp run_spawn_agent(ctx, %ToolCall{} = tc) do
    opts = spawn_opts_from_args(tc)
    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(
           parent_via_tuple,
           {:spawn_agent_request, self(), opts},
           @spawn_request_timeout
         ) do
      {:ok, spawned_name} ->
        build_tool_result(tc, "agents-spawn", spawn_confirmation(spawned_name, opts.query))

      {:error, reason} ->
        build_tool_result(tc, "agents-spawn", spawn_error_message(reason), true)
    end
  end

  # The confirmation the model reads. It says what actually happens — the answer
  # arrives as a message, or a notice saying why it will not — and never says
  # "asynchronously": there is no synchronous mode left to contrast with.
  defp spawn_confirmation(spawned_name, "") do
    "Spawned agent #{spawned_name}. It was given no query, so it has nothing to " <>
      "report back."
  end

  defp spawn_confirmation(spawned_name, _query) do
    "Spawned agent #{spawned_name} with your query. Its answer will arrive as a " <>
      "message in your inbox; if it fails or is stopped before it answers, a " <>
      "runtime notice saying so will arrive instead. Use `agents-wait` to wait " <>
      "for it to finish."
  end

  # Extract the `agents-spawn` args into an opts map, applying defaults. Kept
  # separate so `run_spawn_agent/2` stays under the credo ABC cap.
  defp spawn_opts_from_args(tc) do
    %{
      name: extract_string_arg(tc, "name"),
      vocation: extract_string_arg(tc, "vocation"),
      clone_context: extract_bool_arg(tc, "clone_context", false),
      model: extract_string_arg(tc, "model"),
      query: extract_string_arg(tc, "query"),
      archive: extract_bool_arg(tc, "archive", false)
    }
  end

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

  # `agents-query`: deliver a message to a peer in this space and mark that the
  # peer owes the caller a reply. Nothing waits — the call returns as soon as the
  # delivery is decided (or immediately reports why it could not be delivered),
  # and the peer's answer arrives later as a message in the caller's inbox, with
  # the peer kept in its turn until it answers.
  defp run_query_agent(ctx, %ToolCall{} = tc) do
    target = extract_string_arg(tc, "name")
    prompt = extract_string_arg(tc, "prompt")

    cond do
      target == "" ->
        build_tool_result(tc, "agents-query", "Missing required argument: name.", true)

      prompt == "" ->
        build_tool_result(tc, "agents-query", "Missing required argument: prompt.", true)

      true ->
        deliver_query(ctx, tc, target, prompt)
    end
  end

  defp deliver_query(ctx, tc, target, prompt) do
    case Nest.Agents.send_message(ctx.space_id, ctx.agent_name, target, prompt, :query) do
      {:ok, disposition} ->
        build_tool_result(tc, "agents-query", query_confirmation(target, disposition))

      {:error, :not_found} ->
        build_tool_result(tc, "agents-query", "Agent #{target} not found in this space.", true)

      {:error, reason} ->
        build_tool_result(tc, "agents-query", refusal_message("query", target, reason), true)
    end
  end

  # The confirmation the model reads. It never says "asynchronously": there is no
  # synchronous mode, so the *reply* is what the peer owes, and the answer comes
  # back as a message.
  defp query_confirmation(target, :delivered) do
    "Query delivered to #{target}, which now owes you a reply: it stays in its " <>
      "turn until it answers, and its answer will arrive as a message in your " <>
      "inbox. Use `agents-wait` to wait for it."
  end

  defp query_confirmation(target, :queued) do
    "Query queued for #{target} (busy): it will be delivered at its next turn " <>
      "boundary, and #{target} owes you a reply from then on. The answer will " <>
      "arrive as a message in your inbox."
  end

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
        notify_reply_sent(ctx, target)
        build_tool_result(tc, "agents-send", "Message delivered to #{target}.")

      {:ok, :queued} ->
        notify_reply_sent(ctx, target)
        build_tool_result(tc, "agents-send", "Message queued for #{target} (busy).")

      {:error, :not_found} ->
        build_tool_result(tc, "agents-send", "Agent #{target} not found in this space.", true)

      {:error, reason} ->
        build_tool_result(tc, "agents-send", refusal_message("send to", target, reason), true)
    end
  end

  # A successful outbound send discharges the debt to `target` (issue #31
  # §1.4). The clear travels as a cast to this agent because the tool worker is
  # a separate process; casting it *before* the worker's `{:tool_results, …}` is
  # load-bearing — same sender, same destination, so BEAM FIFO order guarantees
  # the machine has discharged the debt before the response that settles the
  # turn. A cast (not a raw `send/2`) is what routes it through the agent's
  # `handle_cast/2` like every other worker result. A failed send clears nothing
  # (decision 11), which is why only the two success arms of
  # `deliver_to_target/4` call this.
  defp notify_reply_sent(ctx, target) do
    GenServer.cast(ctx.agent_pid, {:reply_sent, target})
  end

  # The delivery refusals both sub-agent delivery tools can hit, worded per tool:
  # `verb` is "send to" for `agents-send` and "query" for `agents-query`.
  defp refusal_message(verb, target, :inbox_full) do
    "Could not #{verb} #{target}: its inbox is full."
  end

  defp refusal_message(verb, target, {:status, status}) do
    "Could not #{verb} #{target}: it is in a #{status} state."
  end

  defp refusal_message(verb, target, reason),
    do: "Could not #{verb} #{target}: #{inspect(reason)}"

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

  # `agents-batch`: fan ONE templated instruction out over a set of items to
  # concurrent sub-agents and receive the aggregate — a JSON array of each
  # child's final response, in item order — later, as a message in this agent's
  # inbox. Nothing waits (§2.3): the fan-out runs in a supervised coordinator
  # whose last act enqueues the aggregate, so this call returns the confirmation
  # as soon as the batch is launched. A whole-call failure that is knowable
  # before the launch (bad items, a bad glob, a template with no placeholder) is
  # this tool's own error result.
  defp run_agents_batch(ctx, %ToolCall{} = tc) do
    case BatchCoordinator.run(ctx, tc) do
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

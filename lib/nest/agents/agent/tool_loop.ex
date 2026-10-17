defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by the in-process turn (`Nest.Agents.Agent.Turn`) after a
  response with `tool_calls` is received. Responsibilities:

    * Split the batch by tool — sub-agent tools (`agents-spawn`,
      `agents-query`, `agents-send`, `agents-wait`,
      `agents-last-message`, `agents-history`, `agents-status`,
      `agents-list`, `agents-list-archived`,
      `agents-archive`, `agents-unarchive`, `agents-batch`,
      `models-list`) are routed through their `run_*` handlers, which run
      in this worker and never in the agent GenServer; everything else is
      delegated to `Nest.Agents.Agent.BatchSizer`.
    * Merge the two halves back into input order.

  `context-compact` is no longer routed through this module — the chat turn's
  response handler detects it ahead of the tool worker, persists the call and
  its synthetic result, and exits with a `{:compact_resume, _, _}`
  continuation. The blocked-tool-worker pattern (where the tool worker awaited
  the compactor on receive) is gone, and so are the `context_compact?/1` and
  `strip_context_compact/1` helpers that once kept `context-compact` out of
  `BatchSizer`'s preflight projection: nothing in the repo called them.
  """

  alias Nest.Agents.Agent.Archive
  alias Nest.Agents.Agent.BatchCoordinator
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.History
  alias Nest.Agents.Agent.LastMessage
  alias Nest.Agents.Agent.ModeAuthority
  alias Nest.Agents.Agent.Status
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Agents.Agent.ToolLoop.ModelEntry
  alias Nest.Agents.Agent.Watch
  alias Nest.Agents.Registry
  alias Nest.DotConfig
  alias Nest.Messages.Part
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
  Run a tool-call batch. Returns the batch's message parts in
  input order — a `ToolResult` per call, plus a media part
  beside any `file-read` that attached one.

  The `state` argument is unused; kept in the signature for
  symmetry with the call site.
  """
  @spec execute(map(), term(), [ToolCall.t()]) :: [Part.t()]
  def execute(ctx, _state, tool_calls) do
    case tool_calls do
      [] -> []
      calls -> run_batch(ctx, calls)
    end
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
        %ToolResult{content: content, is_error: is_error, state: state} =
          run_sub_agent_tool(ctx, tc)

        {tc, entry_kind(is_error, state), content}
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

  # The entry kind `BatchSizer` cooks the result part from. A result that is not
  # a verdict — a wait tool's, whose real result arrives later as a message
  # (issue #54) — keeps its own kind, so the part it becomes carries the marker
  # the machine reads to end the turn.
  defp entry_kind(true, _state), do: :error
  defp entry_kind(false, "waiting"), do: :waiting
  defp entry_kind(false, _state), do: :ok

  defp sub_agent_tool?(%ToolCall{name: name})
       when name in [
              "agents-spawn",
              "agents-query",
              "agents-list",
              "agents-list-archived",
              "agents-archive",
              "agents-unarchive",
              "agents-batch",
              "agents-send",
              "agents-wait",
              "agents-last-message",
              "agents-history",
              "agents-status",
              "models-list"
            ],
       do: true

  defp sub_agent_tool?(_), do: false

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-spawn"} = tc), do: run_spawn_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-query"} = tc), do: run_query_agent(ctx, tc)
  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-send"} = tc), do: run_send_agent(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-wait"} = tc),
    do: run_wait_for_idle(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-last-message"} = tc),
    do: run_last_message(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-history"} = tc),
    do: run_history(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-status"} = tc), do: run_status(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-list"} = tc), do: run_list_agents(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-list-archived"} = tc),
    do: run_list_archived_agents(ctx, tc)

  defp run_sub_agent_tool(_ctx, %ToolCall{name: "models-list"} = tc), do: run_models_list(tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-batch"} = tc),
    do: run_agents_batch(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-archive"} = tc),
    do: run_archive_agent(ctx, tc)

  defp run_sub_agent_tool(ctx, %ToolCall{name: "agents-unarchive"} = tc),
    do: run_unarchive_agent(ctx, tc)

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
      "runtime notice saying so will arrive instead. Use `agents-wait` " <>
      "to be notified when it finishes, and `agents-last-message` to read its " <>
      "message."
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
      archive: extract_bool_arg(tc, "archive", false),
      # The child's mode. `PreSpawn` holds it to the monotone rule (a `plan`
      # parent cannot spawn an `act` child), so this only has to carry what the
      # caller asked for.
      mode: extract_string_arg(tc, "mode")
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

  # The space's blueprint names no default, so an omitted `vocation` has no
  # answer — see `Nest.Agents.Supervisor.resolve_spawn_vocation/2`. The allowed
  # list is included because it is the one thing that makes the retry easy: the
  # model has to pass a slug, and a restricted space will refuse most guesses.
  defp spawn_error_message({:vocation_required, allowed}) do
    allowed_hint =
      case allowed do
        [] ->
          "This space allows any vocation"

        labels ->
          "Allowed vocations: " <>
            Enum.map_join(labels, ", ", fn {name, slug} -> "#{name} (#{slug})" end)
      end

    "Could not spawn agent: `vocation` is required — this space's blueprint names " <>
      "no default vocation, so it cannot be omitted. #{allowed_hint}; retry " <>
      "passing one as `vocation`."
  end

  # An unsafe `name` is the likeliest way an LLM trips validation
  # (`"code reviewer"`, `"Reviewer 2"`): `Agents.create_agent/3` returns the
  # changeset from `PersistedAgent.changeset/2`, whose name rule is
  # `[A-Za-z0-9_-]+`. Render that rule plainly — the catch-all below would
  # dump a whole `#Ecto.Changeset<…>` struct into the model's context, which
  # is both noisy and useless to it. (A duplicate name never arrives here:
  # `Persistence.do_insert/1` translates the unique violation to
  # `{:error, :duplicate_name}`.)
  defp spawn_error_message(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :name) do
      "Could not spawn agent: the name must be non-empty and contain only " <>
        "letters, digits, `_` and `-` (no spaces or slashes). " <>
        "Retry with a different `name`."
    else
      "Could not spawn agent: the request was rejected (#{inspect(errors)})."
    end
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

  # `agents-list-archived`: read the space's archived agents and
  # serialize their name, parent, and depth. Pure read — no
  # GenServer round-trip needed, like `agents-list`.
  defp run_list_archived_agents(ctx, %ToolCall{} = tc) do
    listing =
      Nest.Agents.list_archived_agents_for_space(ctx.space_id)
      |> Enum.map(fn info ->
        %{
          name: info.name,
          parent: info.parent_name,
          depth: info.depth
        }
      end)

    content =
      if listing == [] do
        "No archived agents in this space."
      else
        listing |> inspect() |> String.slice(0, @list_agents_max_chars)
      end

    build_tool_result(tc, "agents-list-archived", content)
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
    case exposed_providers() do
      {:error, reason} ->
        "No models are listed: the configuration could not be read (#{load_failure_text(reason)})."

      {:ok, exposed} when map_size(exposed) == 0 ->
        "No models are listed: no configured provider has expose-models enabled."

      {:ok, exposed} ->
        lines =
          Models.list()
          |> Enum.filter(&model_exposed?(&1, exposed, provider))
          |> Enum.map(&ModelEntry.format(&1, exposed))

        case lines do
          [] -> "No models match the request."
          _ -> lines |> Enum.join("\n") |> String.slice(0, @list_models_max_chars)
        end
    end
  end

  defp load_failure_text(reason) when is_binary(reason), do: reason
  defp load_failure_text(reason), do: inspect(reason)

  # The providers configured with `expose_models: true`, keyed by name, or the
  # load failure itself — kept apart because only one of the two is a
  # configuration state, and reporting "no provider has expose-models enabled"
  # for a config we could not read tells the agent something false.
  #
  # The struct is kept rather than just the name so a model entry can read
  # its provider's tags without a second lookup: tags are what
  # `agents-spawn`'s tag filter matches on, and they live on the provider.
  defp exposed_providers do
    case DotConfig.load() do
      {:ok, config} ->
        {:ok,
         config.providers
         |> Map.values()
         |> Enum.filter(& &1.expose_models)
         |> Map.new(&{&1.name, &1})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A model entry qualifies when its provider exposes models (and,
  # when a filter is given, matches it). Entries without a provider
  # never qualify — the expose flag lives on the provider.
  defp model_exposed?(%{"provider" => p}, exposed, provider_filter) when is_binary(p) do
    Map.has_key?(exposed, p) and (provider_filter == "" or p == provider_filter)
  end

  defp model_exposed?(%{}, _exposed, _provider_filter), do: false

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
        case requested_mode(ctx, tc, target) do
          {:ok, mode} -> deliver_query(ctx, tc, target, prompt, mode)
          {:error, reason} -> build_tool_result(tc, "agents-query", reason, true)
        end
    end
  end

  defp deliver_query(ctx, tc, target, prompt, mode) do
    case Nest.Agents.send_message(ctx.space_id, ctx.agent_name, target, prompt, :query, mode) do
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
      "inbox. Use `agents-wait` to be notified when it answers, and " <>
      "`agents-last-message` to read its message."
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
        case requested_mode(ctx, tc, target) do
          {:ok, mode} -> deliver_to_target(ctx, tc, target, message, mode)
          {:error, reason} -> build_tool_result(tc, "agents-send", reason, true)
        end
    end
  end

  defp deliver_to_target(ctx, tc, target, message, mode) do
    case Nest.Agents.send_message(ctx.space_id, ctx.agent_name, target, message, :agent, mode) do
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

  # `agents-wait`: register interest (issue #54). Nothing waits here: the watch
  # is reported on the result as `state: "waiting"`, which the machine reads and
  # ends the caller's turn for; the watcher's notice is what wakes the agent. A
  # wait with nothing to watch reports inline and the turn continues.
  defp run_wait_for_idle(ctx, %ToolCall{} = tc) do
    case Watch.register_call(ctx, tc) do
      {:waiting, content} -> build_tool_result(tc, "agents-wait", content, false, "waiting")
      {:ok, content} -> build_tool_result(tc, "agents-wait", content)
      {:error, content} -> build_tool_result(tc, "agents-wait", content, true)
    end
  end

  # `agents-last-message`: the explicit content fetch (issue #62). Reads the
  # pending delivery from `name` out of the caller's own inbox, mid-turn, and
  # consumes it.
  defp run_last_message(ctx, %ToolCall{} = tc) do
    case LastMessage.run(ctx, tc) do
      {:ok, content} ->
        build_tool_result(tc, "agents-last-message", SubAgentResults.bound(content, tc, ctx))

      {:error, content} ->
        build_tool_result(tc, "agents-last-message", content, true)
    end
  end

  # `agents-history` (issue #22): a plain DB read of another agent's persisted
  # sequence, so it is callable mid-turn and never touches the target's process.
  # A range read of tool-heavy history can be arbitrarily large, so it goes
  # through the same inline cap every response-bearing sub-agent result does.
  defp run_history(ctx, %ToolCall{} = tc) do
    case History.run(ctx, tc) do
      {:ok, content} ->
        build_tool_result(tc, "agents-history", SubAgentResults.bound(content, tc, ctx))

      {:error, content} ->
        build_tool_result(tc, "agents-history", content, true)
    end
  end

  # `agents-status` (issue #22): the target's message count, compaction boundary
  # and state. A fixed set of lines, so nothing to bound.
  defp run_status(ctx, %ToolCall{} = tc) do
    case Status.run(ctx, tc) do
      {:ok, content} -> build_tool_result(tc, "agents-status", content)
      {:error, content} -> build_tool_result(tc, "agents-status", content, true)
    end
  end

  # `agents-archive`: stop + mark the agents a call names archived. Routes
  # through the parent GenServer so the stop/DB write happens in the same
  # process context as other lifecycle operations; the per-name loop and the
  # result shaping live in `Nest.Agents.Agent.Archive`.
  defp run_archive_agent(ctx, %ToolCall{} = tc) do
    {content, is_error} = Archive.run(ctx, tc)
    build_tool_result(tc, "agents-archive", content, is_error)
  end

  # `agents-unarchive`: restore an archived agent in this space —
  # together with its whole archived subtree — to the active list.
  # Routes through the parent GenServer so the DB write happens in the
  # same process context as other lifecycle operations.
  defp run_unarchive_agent(ctx, %ToolCall{} = tc) do
    target = extract_string_arg(tc, "name")
    parent_via_tuple = Registry.via_tuple(ctx.space_id, ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:unarchive_agent_request, self(), target}) do
      {:ok, restored_name} ->
        build_tool_result(tc, "agents-unarchive", "Restored agent #{restored_name}.")

      {:error, reason} ->
        build_tool_result(tc, "agents-unarchive", unarchive_error(target, reason), true)
    end
  end

  # A child under an archived parent is refused rather than restored:
  # the sidebar nests by `parent_name`, so it would render inside the
  # parent's collapsed Archived group and look like nothing happened.
  # Name the parent so the model knows what to restore first.
  defp unarchive_error(target, {:parent_archived, parent}) do
    "Could not restore #{target}: its parent #{parent} is still archived. " <>
      "Restore #{parent} first (restoring it also restores #{target})."
  end

  defp unarchive_error(target, reason), do: "Could not restore #{target}: #{inspect(reason)}"

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

  # The mode a send tool asks the **recipient** to move to, or `nil` when the
  # call asks for no change.
  #
  # `"mine"` is the sender's own current mode, which is what makes the common
  # case — hand this off to someone who may do what I may — one word. The
  # monotone rule is checked here, where the sender's mode is known (`ctx.mode`),
  # and a refusal is returned as this call's error so the sender reads why
  # rather than watching a change quietly not happen.
  #
  # The rule itself is `Nest.Agents.Agent.ModeAuthority`; nothing here decides
  # what is allowed, only which actor is asking.
  defp requested_mode(ctx, tc, target) do
    case extract_string_arg(tc, "set_mode") do
      "" ->
        {:ok, nil}

      "mine" ->
        {:ok, ctx.mode}

      requested ->
        actor = %{
          kind: :agent,
          space_id: ctx.space_id,
          name: ctx.agent_name,
          mode: ctx.mode,
          target: target
        }

        case ModeAuthority.authorize(actor, requested) do
          :ok -> {:ok, requested}
          {:error, reason} -> {:error, reason}
        end
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

  defp build_tool_result(%ToolCall{} = tc, name, content, is_error \\ false, state \\ nil) do
    %ToolResult{
      tool_call_id: tc.id,
      name: name,
      arguments: tc.arguments,
      content: content,
      is_error: is_error,
      state: state
    }
  end
end

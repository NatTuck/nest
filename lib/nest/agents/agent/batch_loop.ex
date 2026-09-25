defmodule Nest.Agents.Agent.BatchLoop do
  @moduledoc """
  Fork-join executor for the `agents-batch` tool.

  Fans ONE templated instruction out over a set of items to concurrent
  sub-agents (paced to `max_concurrency`) and returns a single
  aggregated result: a JSON array of each child's final response
  string, in item order. The model makes ONE tool call and never
  enumerates per-item prompts or tracks child names.

  ## Contract

  * `template` (optional) — if present, must contain `{item}` or
    `{index}` (substituted per item); otherwise the whole call is an
    error. When absent, each item *is* the child's instruction.
  * `items` (a non-empty list) XOR `glob` (expanded via
    `Sandbox.glob/4` to readable regular files).
  * `vocation_id` / `model` (optional) — per child, inherit parent
    when omitted.
  * `timeout` — PER-ITEM ms (default 5 min). A child still running at
    its deadline is abandoned and its slot becomes an `"[error: ...]"`
    marker.
  * `archive` — defaults to `true`; the child is archived after it
    responds.
  * `on_error` — `"collect"` (default: a failed/timed-out item is a
    marker slot, the aggregate still succeeds) or `"fail_fast"` (stop
    at the first failure and return an error).
  * `max_concurrency` (optional) — clamped to the configured ceiling.

  A per-item failure / timeout writes an `"[error: ...]"` marker into
  that item's slot. `is_error: true` on the tool result is reserved
  for whole-call failures (bad glob, no items, missing placeholder,
  both-or-neither of `items`+`glob`, or a spawn that can't proceed).

  ## Concurrency

  The parent's `Nest.Agents.chat/3` is a `GenServer.cast` (it returns
  immediately), so pacing is bounded purely by `max_concurrency`: at
  most that many children are spawned before we start waiting. The
  blocked tool worker is a Task under `TaskSupervisor` (a separate
  process), so its `GenServer.call(parent, {:spawn_agent_request,
  ...})` cannot deadlock against the coordinator — which stays free to
  process `:child_completed` casts while the batch is in flight.
  """

  require Logger

  alias Jason
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox
  alias Nest.Tokens.Estimator

  # Per-item deadline default (5 minutes).
  @default_timeout_ms 300_000

  # Spawn requests are local GenServer calls to the coordinator; a
  # generous but finite bound so a wedged parent can't hang the batch.
  @spawn_call_timeout_ms 30_000

  # Marker prefix for a failed / timed-out item's slot.
  @error_prefix "[error: "

  # Head size (chars) shown inline when the aggregate is offloaded to
  # the scratch dir.
  @offload_head_chars 200

  @doc """
  Run an `agents-batch` tool call. Returns `{:ok, content}` (the JSON
  aggregate, or an offload pointer + head when it exceeds the inline
  cap) or `{:error, reason}` (whole-call failure).
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, tc) do
    args = tc.arguments || %{}

    with {:ok, items} <- resolve_items(args, ctx),
         {:ok, template} <- template_ok(Map.get(args, "template", "")) do
      run_items(ctx, tc, args, items, template)
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  # ---- Item resolution ----

  # `items` (a non-empty list) XOR `glob` (a pattern). Exactly one must
  # be present; the resolved set must be non-empty.
  @spec resolve_items(map(), map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def resolve_items(args, ctx) do
    items = Map.get(args, "items")
    glob = Map.get(args, "glob", "")
    has_items? = is_list(items)
    has_glob? = is_binary(glob) and glob != ""

    cond do
      has_items? and has_glob? ->
        {:error, "pass exactly one of `items` (a list) or `glob` (a pattern), not both"}

      has_items? ->
        if items == [] do
          {:error, "`items` must be a non-empty list"}
        else
          {:ok, items}
        end

      has_glob? ->
        resolve_glob(glob, ctx)

      true ->
        {:error, "pass one of `items` (a non-empty list) or `glob` (a pattern)"}
    end
  end

  defp resolve_glob(glob, ctx) do
    case Sandbox.glob(glob, ctx.caps, ctx.workspace_path) do
      {:ok, files} when files != [] ->
        {:ok, files}

      {:ok, _} ->
        {:error, "glob matched no readable files: #{glob}"}

      {:error, :glob_too_broad} ->
        {:error, "glob matched too many files (over the per-call limit); narrow the pattern"}

      {:error, reason} ->
        {:error, "glob failed: #{inspect(reason)}"}
    end
  end

  # A present template must contain `{item}` or `{index}`; an
  # absent/empty template means "the item string is the instruction".
  @spec template_ok(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def template_ok(template) when template == "", do: {:ok, ""}

  def template_ok(template) do
    if String.contains?(template, "{item}") or String.contains?(template, "{index}") do
      {:ok, template}
    else
      {:error, "`template` must contain `{item}` or `{index}`"}
    end
  end

  # Substitute `{item}` / `{index}` in the template. An empty template
  # means the item string itself is the instruction.
  @spec render(String.t(), non_neg_integer(), String.t()) :: String.t()
  def render("", _index, item), do: item

  def render(template, index, item) do
    template
    |> String.replace("{item}", item)
    |> String.replace("{index}", to_string(index))
  end

  # ---- The fork-join driver ----

  defp run_items(ctx, tc, args, items, template) do
    timeout_ms = int_arg(args, "timeout") || @default_timeout_ms
    max_concurrency = Config.clamp_batch_concurrency(int_arg(args, "max_concurrency"))

    acc = %{
      space_id: ctx.space_id,
      parent: AgentsRegistry.via_tuple(ctx.space_id, ctx.agent_name),
      items: items,
      template: template,
      base_opts: build_base_opts(args),
      names: names_for_space(items, Map.get(args, "name_prefix", ""), ctx.space_id),
      timeout_ms: timeout_ms,
      max_concurrency: max_concurrency,
      on_error: Map.get(args, "on_error", "collect"),
      results: List.duplicate(nil, length(items)),
      # name => {slot_index, absolute_deadline_ms(monotonic)}
      pending: %{},
      next: 0,
      spawned: 0
    }

    case pace(acc.parent, acc) do
      {:ok, acc} ->
        case drain(acc.parent, acc) do
          {:ok, results} -> {:ok, assemble(ctx, tc, results)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        abandon_all(acc.parent, acc.pending)
        {:error, spawn_error_message(reason)}
    end
  end

  # Fill open slots by spawning the next item while we are under the
  # concurrency cap and items remain. Returns `{:ok, acc}` or
  # `{:error, reason}` when a spawn cannot proceed (a whole-call
  # failure for a `collect` batch we can't meaningfully continue).
  defp pace(_parent, acc)
       when acc.spawned >= length(acc.items) or
              map_size(acc.pending) >= acc.max_concurrency,
       do: {:ok, acc}

  defp pace(parent, acc) do
    index = acc.next
    item = Enum.at(acc.items, index)
    instruction = render(acc.template, index, item)
    name = Enum.at(acc.names, index)

    case spawn_child(parent, name, Map.put(acc.base_opts, :query, instruction)) do
      {:ok, ^name} ->
        now = System.monotonic_time(:millisecond)

        acc
        |> Map.put(:pending, Map.put(acc.pending, name, {index, now + acc.timeout_ms}))
        |> Map.update!(:next, &(&1 + 1))
        |> Map.update!(:spawned, &(&1 + 1))
        |> then(&pace(parent, &1))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Consume completions one at a time, re-pacing as slots free, until
  # every slot is filled (by a response or an error/timeout marker).
  defp drain(_parent, acc) when map_size(acc.pending) == 0, do: {:ok, acc.results}

  defp drain(parent, acc) do
    receive do
      {:spawn_agent_result, name, response} ->
        on_result(parent, acc, name, response)

      {:spawn_agent_error, name, reason} ->
        on_error_msg(parent, acc, name, reason)
    after
      next_wait(acc) ->
        handle_deadlines(parent, acc)
    end
  end

  # A response for a still-pending child fills its slot; a response for
  # an already-abandoned child (a completion racing our timeout) is
  # dropped.
  defp on_result(parent, acc, name, response) do
    case Map.fetch(acc.pending, name) do
      {:ok, {index, _deadline}} ->
        step(parent, set_done(acc, index, response, name))

      :error ->
        drain(parent, acc)
    end
  end

  defp on_error_msg(parent, acc, name, reason) do
    case Map.fetch(acc.pending, name) do
      {:ok, {index, _deadline}} ->
        acc = set_done(acc, index, marker("failed: #{inspect(reason)}"), name)

        if acc.on_error == "fail_fast" do
          finish_failure(parent, acc, "item #{index} failed: #{inspect(reason)}")
        else
          step(parent, acc)
        end

      :error ->
        drain(parent, acc)
    end
  end

  # Re-pace to fill the freed slot, then continue (or fail on spawn error).
  defp step(parent, acc) do
    case pace(parent, acc) do
      {:ok, acc} -> drain(parent, acc)
      {:error, reason} -> finish_failure(parent, acc, spawn_error_message(reason))
    end
  end

  # Write `value` into slot `index` and drop `name` from the pending set.
  defp set_done(acc, index, value, name) do
    acc
    |> Map.update!(:results, &List.replace_at(&1, index, value))
    |> Map.put(:pending, Map.delete(acc.pending, name))
  end

  # How long to wait before the next deadline check: the soonest pending
  # child's deadline, or 0 if one has already passed.
  defp next_wait(acc) do
    now = System.monotonic_time(:millisecond)
    min_deadline = acc.pending |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.min()
    max(0, min_deadline - now)
  end

  # Abandon every child past its deadline (stopping the process and
  # clearing the parent's bookkeeping) and write a timeout marker into
  # each of its slots.
  defp handle_deadlines(parent, acc) do
    now = System.monotonic_time(:millisecond)

    {timed_out, remaining} =
      Enum.split_with(acc.pending, fn {_name, {_index, deadline}} -> deadline <= now end)

    acc = %{
      acc
      | results: abandon_timed_out(parent, timed_out, acc.results, acc.timeout_ms),
        pending: remaining
    }

    cond do
      acc.on_error == "fail_fast" and map_size(timed_out) > 0 ->
        finish_failure(parent, acc, "an item timed out after #{acc.timeout_ms}ms")

      map_size(remaining) == 0 ->
        {:ok, acc.results}

      true ->
        drain(parent, acc)
    end
  end

  # Abandon each timed-out child (stopping the process) and write a
  # timeout marker into its slot.
  defp abandon_timed_out(parent, timed_out, results, timeout_ms) do
    Enum.reduce(timed_out, results, fn {name, {index, _deadline}}, acc_results ->
      _ = GenServer.call(parent, {:abandon_child, self(), name})
      List.replace_at(acc_results, index, marker("timed out after #{timeout_ms}ms"))
    end)
  end

  # Whole-call failure: stop every still-pending child and surface the
  # reason.
  defp finish_failure(parent, acc, reason) do
    abandon_all(parent, acc.pending)
    {:error, reason}
  end

  # ---- Spawn / abandon plumbing ----

  defp spawn_child(parent, name, base_opts) do
    opts = Map.put(base_opts, :name, name)

    case GenServer.call(parent, {:spawn_agent_request, self(), opts}, @spawn_call_timeout_ms) do
      {:ok, spawned_name} -> {:ok, spawned_name}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- Child naming ----

  # Names for the batch children, derived from each item so the
  # sidebar is readable (an "assignment id" becomes the child's
  # name) instead of a generated adjective-animal pair. The item is
  # slugified; when the same item appears more than once, each
  # occurrence gets a `-<n>` suffix (1-based). `name_prefix` is an
  # optional constant prefix.
  #
  #   names_for_items([1, 12, 8, 1, "goat"], "zoo")
  #   #=> ["zoo-1-1", "zoo-12", "zoo-8", "zoo-1-2", "zoo-goat"]
  #
  # Pure (no space/registry access); `run_items/5` then runs the
  # result through `uniquify/2` so a name never collides with an
  # existing agent in the space.
  @doc false
  @spec names_for_items([term()], String.t()) :: [String.t()]
  def names_for_items(items, prefix) do
    slugs =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> item_slug(item, index) end)

    counts = Enum.frequencies(slugs)

    {names, _seen} =
      Enum.map_reduce(slugs, %{}, fn slug, seen ->
        occurrence = Map.get(seen, slug, 0) + 1
        name = base_name(prefix, slug, occurrence, Map.fetch!(counts, slug))
        {name, Map.put(seen, slug, occurrence)}
      end)

    names
  end

  # `run_items/5` entry point: derive item names, then make them unique
  # against the space's live + persisted names.
  defp names_for_space(items, prefix, space_id) do
    items
    |> names_for_items(prefix)
    |> uniquify(Supervisor.existing_names_for_space(space_id))
  end

  # Slugify an item. Items can be integers (assignment ids) or
  # strings (including paths); anything that isn't `[a-z0-9]` becomes a
  # single `-`. A slug that comes out empty (e.g. all punctuation)
  # falls back to a deterministic `item-<n>`.
  defp item_slug(item, index) do
    slug =
      item
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 64)

    if slug == "", do: "item-#{index + 1}", else: slug
  end

  defp base_name(prefix, slug, occurrence, total) do
    base = if prefix == "", do: slug, else: prefix <> "-" <> slug
    if total > 1, do: base <> "-" <> Integer.to_string(occurrence), else: base
  end

  # Make each name unique against `existing` (and against the names
  # already reserved earlier in the same list) by appending `-2`,
  # `-3`, ... until free.
  defp uniquify(names, existing) do
    {result, _used} =
      Enum.map_reduce(names, existing, fn name, used ->
        final = unique_variant(name, used, 1)
        {final, MapSet.put(used, final)}
      end)

    result
  end

  defp unique_variant(name, used, n) do
    candidate = if n == 1, do: name, else: name <> "-" <> Integer.to_string(n)

    if MapSet.member?(used, candidate) do
      unique_variant(name, used, n + 1)
    else
      candidate
    end
  end

  defp abandon_all(parent, pending) do
    Enum.each(Map.keys(pending), fn name ->
      try do
        GenServer.call(parent, {:abandon_child, self(), name})
      catch
        _, _ -> :ok
      end
    end)
  end

  # Build the spawn opts the coordinator's `:spawn_agent_request`
  # handler reads. `:name` and `:query` are set per child at spawn time;
  # `:archive` defaults to true (children are cleaned up after
  # responding); `:clone_context` is always false (a batch child is a
  # fresh specialist, never a context fork).
  defp build_base_opts(args) do
    %{
      name: "",
      vocation_id: int_arg(args, "vocation_id"),
      clone_context: false,
      model: Map.get(args, "model", ""),
      query: "",
      archive: Map.get(args, "archive", true)
    }
  end

  # ---- Result assembly ----

  # Encode the ordered slot list as a JSON array, offloading to the
  # scratch dir (with a pointer + head inline) when it exceeds the
  # effective inline cap.
  defp assemble(ctx, tc, results) do
    json = results |> Enum.map(&slot_to_string/1) |> Jason.encode!()
    offload_if_needed(ctx, tc, json, length(results))
  end

  defp offload_if_needed(ctx, tc, json, count) do
    usable = CapCalculator.usable_remaining(ctx)

    if usable > 0 and
         Estimator.estimate(json) > CapCalculator.effective_max_result_tokens(tc, usable) do
      path = Overflow.write(json, ctx, "agents-batch", "json") || "(scratch unavailable)"
      head = String.slice(json, 0, @offload_head_chars)

      "Batch of #{count} results (~#{Estimator.estimate(json)} tokens) saved to #{path}. " <>
        "Head: #{head}"
    else
      json
    end
  end

  # A nil slot (shouldn't survive a completed drain) becomes a marker
  # rather than JSON `null`.
  defp slot_to_string(nil), do: marker("no result")
  defp slot_to_string(value) when is_binary(value), do: value

  # ---- small helpers ----

  defp marker(message), do: @error_prefix <> message <> "]"

  defp int_arg(args, key) do
    case Map.get(args, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  # Format a spawn failure for the model. `:vocation_not_spawnable`
  # carries the whitelisted `{name, id}` vocations; other reasons
  # (max depth, duplicate name, workspace required) are rendered
  # directly.
  defp spawn_error_message({:vocation_not_spawnable, allowed}) do
    labels = Enum.map_join(allowed, ", ", fn {name, id} -> "#{name} (id #{id})" end)
    "Could not spawn batch children: vocation not allowed in this space. Allowed: #{labels}."
  end

  defp spawn_error_message(:max_depth_reached),
    do: "Could not spawn batch children: max delegation depth reached."

  defp spawn_error_message(reason), do: "Could not spawn batch children: #{inspect(reason)}"
end

defmodule Nest.Agents.Agent.BatchPlan do
  @moduledoc """
  Pure planning, naming and assembly for the `agents-batch` tool.

  The fork-join itself lives in `Nest.Agents.Agent.BatchCoordinator`, which fans
  this plan out, watches each child's outcome arrive in the parent's inbox, and
  enqueues the aggregate. Everything here can be decided without running
  anything: item resolution (`items` XOR `glob`), the template check and
  rendering, the children's names, the `[error: ...]` slot markers, the JSON
  aggregate (offloaded to the scratch dir when it exceeds the inline cap), and
  the model-facing failure wording.

  ## Contract

  * `template` (optional) — if present, must contain `{item}` or
    `{index}` (substituted per item); otherwise the whole call is an
    error. When absent, each item *is* the child's instruction.
  * `items` (a non-empty list of non-blank strings or integers) XOR `glob`
    (expanded via `Sandbox.glob/4` to readable regular files). A blank or
    otherwise unusable item is a whole-call error, not a slot marker: it is
    knowable before the launch.
  * `vocation` (slug) / `model` (optional) — per child, inherit parent
    when omitted.
  * `timeout` — PER-ITEM ms (default 5 min). A child still running at
    its deadline is abandoned and its slot becomes an `"[error: ...]"`
    marker.
  * `archive` — defaults to `true`; the child is archived after it
    responds.
  * `on_error` — `"collect"` (default: a failed/timed-out item is a
    marker slot, the aggregate still succeeds) or `"fail_fast"` (stop
    at the first failure and report it).
  * `max_concurrency` (optional) — clamped to the configured ceiling.

  A per-item failure / timeout — or a child that finished without
  producing any text — writes an `"[error: ...]"` marker into that
  item's slot, so a slot is never silently empty. A whole-call failure
  (bad glob, no items, missing placeholder, both-or-neither of
  `items`+`glob`) is the tool result itself; a spawn that cannot proceed
  is reported in the inbox, because the call has already returned by
  then.
  """

  require Logger

  alias Jason
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.Sandbox
  alias Nest.Tokens.Estimator

  # Per-item deadline default (5 minutes).
  @default_timeout_ms 300_000

  # Marker prefix for a failed / timed-out item's slot.
  @error_prefix "[error: "

  @doc """
  The plan for one `agents-batch` call: what to spawn, in what order, under
  which deadline and concurrency, and where the slots land. Built in the calling
  tool worker — the names are made unique against the space, which reads the
  database — so the coordinator itself needs no database access.
  """
  @spec new(map(), map(), [String.t()], String.t()) :: map()
  def new(ctx, args, items, template) do
    %{
      space_id: ctx.space_id,
      parent_pid: ctx.agent_pid,
      parent_name: ctx.agent_name,
      parent: AgentsRegistry.via_tuple(ctx.space_id, ctx.agent_name),
      ctx: ctx,
      items: items,
      template: template,
      base_opts: base_opts(args),
      names: names_for_space(items, Map.get(args, "name_prefix", ""), ctx.space_id),
      timeout_ms: int_arg(args, "timeout") || @default_timeout_ms,
      max_concurrency: Config.clamp_batch_concurrency(int_arg(args, "max_concurrency")),
      on_error: Map.get(args, "on_error", "collect"),
      results: List.duplicate(nil, length(items)),
      # name => {slot_index, absolute_deadline_ms(monotonic)}
      pending: %{},
      next: 0,
      spawned: 0
    }
  end

  # Build the spawn opts the parent's `:spawn_agent_request` handler reads.
  # `:name` and `:query` are set per child at spawn time; `:archive` defaults to
  # true (children are cleaned up after responding); `:clone_context` is always
  # false (a batch child is a fresh specialist, never a context fork).
  defp base_opts(args) do
    %{
      name: "",
      vocation: Map.get(args, "vocation"),
      clone_context: false,
      model: Map.get(args, "model", ""),
      query: "",
      archive: Map.get(args, "archive", true)
    }
  end

  # ---- Item resolution ----

  # `items` (a non-empty list of usable items) XOR `glob` (a pattern). Exactly
  # one must be present; the resolved set must be non-empty, and every item in
  # it must be usable (see `usable_item?/1`).
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
        validate_items(items)

      has_glob? ->
        resolve_glob(glob, ctx)

      true ->
        {:error, "pass one of `items` (a non-empty list) or `glob` (a pattern)"}
    end
  end

  defp validate_items([]), do: {:error, "`items` must be a non-empty list"}

  defp validate_items(items) do
    case Enum.find_index(items, &(not usable_item?(&1))) do
      nil -> {:ok, items}
      index -> {:error, item_problem(index, Enum.at(items, index))}
    end
  end

  # An item is a non-blank string (an instruction, or a path to one) or an
  # integer (an assignment id). A blank item is rejected rather than dropped: a
  # child spawned for `""` has no instruction — it is never tracked, never runs,
  # and burns the whole per-item timeout before its slot becomes a marker — and
  # dropping it would silently change the item count and the slot indices the
  # caller asked for. The check runs before the launch, so the whole call is an
  # error result the model can correct.
  defp usable_item?(item) when is_integer(item), do: true
  defp usable_item?(item) when is_binary(item), do: String.trim(item) != ""
  defp usable_item?(_item), do: false

  defp item_problem(index, item) when is_binary(item),
    do: "`items[#{index}]` is blank; an item must be a non-blank string or an integer"

  defp item_problem(index, item),
    do: "`items[#{index}]` is #{inspect(item)}; an item must be a non-blank string or an integer"

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
  def names_for_space(items, prefix, space_id) do
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

  # ---- Result assembly ----

  # Encode the ordered slot list as a JSON array, offloading to the scratch dir
  # (with a pointer + head inline) when it exceeds the effective inline cap.
  def assemble(ctx, tc, results) do
    encode_and_offload(ctx, tc, Enum.map(results, &slot_to_string/1))
  end

  @doc """
  The aggregate for a batch that stopped before every slot was filled: the same
  ordered JSON array as `assemble/3`, with a slot no child ever filled saying so.

  A stopped batch still reports what came back — a child's answer that arrived
  before the stop is not discarded along with the rest — so the model sees the
  answers it did get, in item order, next to the reason the rest stopped.
  """
  @spec assemble_stopped(map(), term(), [term()]) :: String.t()
  def assemble_stopped(ctx, tc, results) do
    encode_and_offload(ctx, tc, Enum.map(results, &stopped_slot_to_string/1))
  end

  defp encode_and_offload(ctx, tc, slots) do
    offload_if_needed(ctx, tc, Jason.encode!(slots), length(slots))
  end

  defp stopped_slot_to_string(nil), do: marker("not run: the batch stopped")

  defp stopped_slot_to_string(value), do: slot_to_string(value)

  defp offload_if_needed(ctx, tc, json, count) do
    usable = CapCalculator.usable_remaining(ctx)

    if usable > 0 and
         Estimator.estimate(json) > CapCalculator.effective_max_result_tokens(tc, usable) do
      cap = CapCalculator.effective_max_result_tokens(tc, usable)
      Overflow.substitute(json, ctx, "Batch of #{count} results", cap, "agents-batch")
    else
      json
    end
  end

  # A child that replied with no text becomes a marker rather than JSON `""`,
  # so a slot is never silently empty.
  @doc """
  The string for one aggregate slot.

  A `nil` slot is unreachable from `assemble/3`: every item is spawned, and every
  spawned child's outcome is either consumed or timed out (writing a marker)
  before `drain/2`'s guard clause can call `finish/2`. It says so rather than
  going out as JSON `null`, because a slot is never silently empty — and
  `assemble_stopped/3` uses this clause for a slot a stop left unfilled.
  """
  @spec slot_to_string(term()) :: String.t()
  def slot_to_string(nil), do: marker("no result")

  def slot_to_string(""), do: marker("finished its turn without producing any text")

  def slot_to_string(value) when is_binary(value), do: value

  # ---- small helpers ----

  def marker(message), do: @error_prefix <> message <> "]"

  defp int_arg(args, key) do
    case Map.get(args, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc "The whole-call failure text the tool returns."
  @spec error_message(term()) :: String.t()
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason), do: inspect(reason)

  # Format a spawn failure for the model. `:vocation_not_spawnable`
  # carries the whitelisted `{name, slug}` vocations; other reasons
  # (max depth, duplicate name, workspace required) are rendered
  # directly.
  def spawn_error_message({:vocation_not_spawnable, allowed}) do
    labels = Enum.map_join(allowed, ", ", fn {name, slug} -> "#{name} (#{slug})" end)
    "Could not spawn batch children: vocation not allowed in this space. Allowed: #{labels}."
  end

  def spawn_error_message({:vocation_not_found, slug}),
    do: "Could not spawn batch children: no vocation with slug #{inspect(slug)} exists."

  def spawn_error_message(:max_depth_reached),
    do: "Could not spawn batch children: max delegation depth reached."

  def spawn_error_message(reason), do: "Could not spawn batch children: #{inspect(reason)}"
end

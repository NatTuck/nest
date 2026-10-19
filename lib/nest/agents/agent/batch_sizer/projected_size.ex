defmodule Nest.Agents.Agent.BatchSizer.ProjectedSize do
  @moduledoc """
  Per-tool projection of the post-execution message size for
  the BatchSizer's preflight phase. Each clause returns the
  estimated token count for the tool result if the call
  succeeds; the BatchSizer sums these projections plus the
  current message-list size plus the LLM compaction reserve
  and refuses the batch if the total exceeds
  `context_limit`.

  Extracted from `BatchSizer` to keep that module under
  credo's 500-line cap.

  ## Adding a new tool

  When a real tool is added to `Nest.Tools`, add a
  `projected_size/2` clause below with a regression test in
  `test/nest/agents/agent/batch_sizer_test.exs`. The
  catch-all in this file is for the LLM's typos and
  hallucinated names, NOT for registered-but-unprojected
  tools.
  """

  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.RequestSize
  alias Nest.Tools.MediaKind

  @safety_padding 1.20

  # `agents-list` / `agents-list-archived` / `models-list` are
  # hard-sliced to this many chars in `Nest.Agents.Agent.ToolLoop`;
  # their projection is bounded by it.
  @max_list_chars 4_000

  # Per-tool projections. The `BatchSizer.preflight/2` sums
  # these across the batch plus the current message-list size
  # plus the LLM compaction reserve, and refuses the batch if
  # the total exceeds `context_limit`.
  def project(%ToolCall{name: "file-read"} = tc, ctx), do: read_file_projection(tc, ctx)
  def project(%ToolCall{name: "shell-cmd"}, _ctx), do: summary_baseline_size() * @safety_padding

  def project(%ToolCall{name: "file-write"}, _ctx),
    do: estimator_overhead("Successfully wrote N bytes to path.txt")

  def project(%ToolCall{name: "file-edit"}, _ctx),
    do: estimator_overhead("Replaced N occurrence(s) in path.txt")

  def project(%ToolCall{name: "file-inspect"}, _ctx) do
    # file-inspect's largest historical output (~256 tokens of
    # stats); metric scale-up by repeating the format's longest line.
    estimator_overhead(
      "File: path/to/file.txt\n" <>
        "Type: ASCII text\n" <>
        "Size: N bytes\n" <>
        "Lines: N\n" <>
        "Non-blank lines: N\n" <>
        "Characters: N\n" <>
        "Max line length: N\n" <>
        "Estimated tokens: ~N"
    )
  end

  def project(%ToolCall{name: "context-check"}, _ctx),
    do:
      estimator_overhead(
        "Context: N messages, ~X / Y tokens used (Z%). Usable remaining: ~R tokens."
      )

  # Shell job tools. `shell-cmd` is above; `shell-wait`/`shell-list` can
  # carry a job's whole log or an arbitrary command string, so they
  # project at the substitute minimum (they are offloaded when over
  # budget). `shell-kill` is a fixed one-liner.
  def project(%ToolCall{name: "shell-wait"}, _ctx), do: summary_baseline_size() * @safety_padding
  def project(%ToolCall{name: "shell-list"}, _ctx), do: summary_baseline_size() * @safety_padding

  def project(%ToolCall{name: "shell-kill"}, _ctx),
    do: estimator_overhead("Killed background job job-N (exit code N).")

  # Sub-agent tools. The response-bearing ones project at the substitute
  # minimum; the listing tools are hard-sliced to `@max_list_chars`.
  def project(%ToolCall{name: "agents-spawn"}, _ctx),
    do: summary_baseline_size() * @safety_padding

  def project(%ToolCall{name: "agents-query"}, _ctx),
    do: summary_baseline_size() * @safety_padding

  def project(%ToolCall{name: "agents-batch"}, _ctx),
    do: summary_baseline_size() * @safety_padding

  def project(%ToolCall{name: name}, _ctx)
      when name in ["agents-list", "agents-list-archived", "models-list"],
      do: Estimator.estimate_bytes(@max_list_chars)

  # One sentence per archived name, so the projection scales with the list
  # `agents-archive` accepts.
  def project(%ToolCall{name: "agents-archive"} = tc, _ctx),
    do: estimator_overhead("Archived agent clever-raven.") * archive_name_count(tc)

  def project(%ToolCall{name: "agents-unarchive"}, _ctx),
    do: estimator_overhead("Restored agent clever-raven.")

  def project(%ToolCall{name: "agents-send"}, _ctx),
    do: estimator_overhead("Message queued for clever-raven.")

  def project(%ToolCall{name: "agents-wait"}, _ctx),
    do: summary_baseline_size() * @safety_padding

  # `agents-history` returns a range read of arbitrary user/tool text, bounded
  # by the per-call cap like the other response-bearing sub-agent tools, so it
  # projects at the substitute minimum.
  def project(%ToolCall{name: "agents-history"}, _ctx),
    do: summary_baseline_size() * @safety_padding

  # `agents-status` is a fixed set of lines; this is one representative report.
  def project(%ToolCall{name: "agents-status"}, _ctx),
    do:
      estimator_overhead(
        "Agent \"clever-raven\": idle (running)\n" <>
          "  messages: 42 (indices 0..41)\n" <>
          "  last compaction index: -1 (never compacted)\n" <>
          "  owed replies: none; pending inbox: 0 message(s)"
      )

  # The pane tools. The three that mutate answer with one short sentence; the
  # two that read answer with a list bounded by the pane's own caps
  # (`Nest.Agents.Agent.Pane`: 50 decisions, 50 TODO items), so they project at
  # the substitute minimum the other bounded-read tools use.
  def project(%ToolCall{name: "decisions-ask"}, _ctx),
    do: estimator_overhead("Recorded question d1 for the user; they will answer later.")

  def project(%ToolCall{name: "decisions-obsolete"}, _ctx),
    do: estimator_overhead("Marked question d1 as no longer needed.")

  def project(%ToolCall{name: "todos-write"}, _ctx),
    do: estimator_overhead("TODO list updated: 12 items.")

  def project(%ToolCall{name: name}, _ctx) when name in ["decisions-list", "todos-list"],
    do: summary_baseline_size() * @safety_padding

  # Catch-all for tools the LLM hallucinates or spells
  # incorrectly. These calls never reach execution; they return
  # small error strings ("Unknown tool: X", "Tool X not
  # registered", "missing required argument", etc.) whose size
  # is far smaller than the worst-case output of a real tool.
  # Project off a representative error so preflight stays
  # honest about what's actually going on the wire.
  #
  # This is NOT the place for registered tools without a
  # specific clause — when a real tool is added to Nest.Tools,
  # add a `projected_size/2` clause above with a regression test.
  def project(%ToolCall{name: name}, _ctx) do
    estimator_overhead("Unknown tool '#{name}'. Use one of the registered tools.")
  end

  # The set of tool names with an explicit projection above. Kept as a
  # single list so a test can assert every registered tool is projected
  # (a new registered tool with only the catch-all is the bug this
  # guards against). `context-compact` is excluded: it is stripped from
  # preflight and never reaches this module.
  @projected_tools ~w(
    file-read shell-cmd file-write file-edit file-inspect context-check
    shell-wait shell-list shell-kill
    agents-spawn agents-query agents-batch agents-list agents-list-archived models-list
    agents-archive agents-unarchive agents-send agents-wait
    agents-history agents-status
    decisions-ask decisions-list decisions-obsolete todos-write todos-list
  )

  @doc false
  @spec projected?(String.t()) :: boolean()
  def projected?(name), do: name in @projected_tools

  @doc """
  Sum of `project/2` over `tool_calls`, sharing one `Sandbox.stat/3` per
  distinct resolved `file-read` path (issue #48).

  `BatchSizer.projected_content_size/2` and `preflight/2` both go through
  here, so a batch never stats the same file twice: the preflight's per-call
  stat used to be one bwrap spawn per `file-read` call.
  """
  @spec project_batch([ToolCall.t()], map()) :: number()
  def project_batch(tool_calls, ctx) when is_list(tool_calls) do
    {tokens, _media_bytes} = project_batch_with_media(tool_calls, ctx)
    tokens
  end

  @doc """
  `project_batch/2` and the batch's media bytes, from **one** stat pass.

  The two have to come from one call: `stat_many/3` is expected to run exactly
  once per response (issue #48), and a caller that needs both numbers would
  otherwise stat twice. `media_bytes/2` reads the memo this puts on `ctx`.
  """
  @spec project_batch_with_media([ToolCall.t()], map()) :: {number(), non_neg_integer()}
  def project_batch_with_media(tool_calls, ctx) when is_list(tool_calls) do
    ctx = Map.put(ctx, :file_read_sizes, read_file_sizes(tool_calls, ctx))
    tokens = Enum.reduce(tool_calls, 0, fn tc, acc -> acc + project(tc, ctx) end)
    {tokens, media_bytes(tool_calls, ctx)}
  end

  @doc """
  The wire bytes a batch's media `file-read` results would add.

  Media is the one tool result whose byte cost is not visible in its token
  price — an image is 4,096 tokens whatever its size — so it is the one a
  batch has to project in bytes. A batch can hold several images that each fit
  under the ceiling alone and still put the request over it together, which is
  why this is a batch-level sum and not a per-call check.

  Reads the sizes `project_batch_with_media/2` memoized. Called on its own it
  pays for a stat pass, so a caller that also wants the token projection should
  use `project_batch_with_media/2` instead.
  """
  @spec media_bytes([ToolCall.t()], map()) :: non_neg_integer()
  def media_bytes(tool_calls, ctx) when is_list(tool_calls) do
    sizes = Map.get(ctx, :file_read_sizes) || read_file_sizes(tool_calls, ctx)

    tool_calls
    |> Enum.flat_map(&media_wire_bytes_for(&1, ctx, sizes))
    |> Enum.sum()
  end

  # The wire bytes one call contributes, or `[]` when it is not a `file-read`
  # of a media path whose size could be read.
  #
  # A path that could not be statted contributes **nothing**, which for a size
  # gate is the direction that lets a request *through* — so this is not a
  # conservative default, it is a known hole. It is covered by `file-read`'s own
  # gate, which runs when the batch is executed and refuses the read that the
  # preflight could not price.
  defp media_wire_bytes_for(
         %ToolCall{name: "file-read", arguments: %{"path" => path}} = tc,
         ctx,
         sizes
       )
       when is_binary(path) do
    with {:ok, _modality} <- MediaKind.from_path(path),
         {:ok, full_path} <- resolved_read_path(tc, ctx),
         # `read_file_sizes/2` maps a path to `{:ok, size}`, so this is the
         # map's value rather than the fetch result.
         {:ok, {:ok, size}} <- Map.fetch(sizes, full_path) do
      [RequestSize.media_wire_bytes(size)]
    else
      _ -> []
    end
  end

  defp media_wire_bytes_for(_tool_call, _ctx, _sizes), do: []

  # ---- private helpers ----

  # The stat result for every distinct path a `file-read` call in this batch
  # targets. Keyed on the *resolved* path, so two spellings of one file share
  # a stat; spellings that resolve differently are statted separately (never a
  # wrong size, at most one extra spawn). `caps` and `mounts` are constant
  # across a `ctx`, so a memo hit is exactly what a live `Sandbox.stat/3`
  # would have returned.
  #
  # `Sandbox.stat_many/3` runs one `stat` invocation for the whole chunk of
  # distinct paths, so the preflight costs a handful of bwrap spawns per batch
  # instead of one per `file-read` call.
  defp read_file_sizes(tool_calls, ctx) do
    paths =
      tool_calls
      |> Enum.flat_map(fn
        %ToolCall{name: "file-read"} = tc ->
          case resolved_read_path(tc, ctx) do
            {:ok, full_path} -> [full_path]
            :error -> []
          end

        _ ->
          []
      end)
      |> Enum.uniq()

    Sandbox.stat_many(paths, caps_of(ctx), Map.get(ctx, :mounts))
  end

  # The path a `file-read` call targets, resolved against the workspace, or
  # `:error` for a malformed call / a relative path with no workspace. Shared
  # with `read_file_projection/2` so the memo can only ever hold paths the
  # projection would itself have statted.
  defp resolved_read_path(%ToolCall{arguments: args}, ctx) do
    with %{"path" => path} <- args,
         true <- is_binary(path) and path != "",
         {:ok, full_path} <- Sandbox.resolve(path, Map.get(ctx, :mounts)) do
      {:ok, full_path}
    else
      _ -> :error
    end
  end

  # The size of one resolved path: from the batch memo when the caller supplied
  # one (see `project_batch/2`), otherwise a live `Sandbox.stat/3`. A memo miss
  # still stats, so `project/2` on its own keeps its old behaviour.
  defp stat_size_for(full_path, ctx) do
    case Map.get(ctx, :file_read_sizes) do
      %{} = sizes -> Map.get_lazy(sizes, full_path, fn -> live_stat_size(full_path, ctx) end)
      _ -> live_stat_size(full_path, ctx)
    end
  end

  # `Sandbox.stat_many/3` returns sizes directly; `Sandbox.stat/3` returns a
  # partial `%File.Stat{}` of which the projection reads only `size`.
  #
  # `full_path` is the path the agent used, in the domain the agent names;
  # `ctx.mounts` is what `Nest.Sandbox` reads the bind layout out of.
  defp live_stat_size(full_path, ctx) do
    case Sandbox.stat(full_path, caps_of(ctx), Map.get(ctx, :mounts)) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  # A media target prices at its modality ceiling — the same number the
  # execution path's cap compares against — so the preflight can refuse BEFORE
  # the read.
  #
  # Gated on the extension, which is only a hint: `file --mime-type` is the
  # authority and costs a bwrap spawn, which the preflight must not pay per
  # call. A wrong guess here can only mis-project, never mis-execute, because
  # the tool re-detects authoritatively at execution time. This asymmetry is
  # deliberate.
  #
  # The gate is what keeps the frozen-oracle parity tests in
  # `batch_sizer_preflight_stat_test.exs` byte-identical: every `.txt` fixture
  # takes `text_read_projection/2` below. Do not widen it. Parity survives the
  # cap clamp in `read_file_projection/2` for a different reason — every fixture
  # there projects under its cap, so the clamp is a no-op for them — and that is
  # the property to keep if a fixture is ever enlarged.
  def read_file_projection(%ToolCall{arguments: %{"path" => path}} = tc, ctx)
      when is_binary(path) do
    projection =
      case MediaKind.from_path(path) do
        {:ok, modality} -> Estimator.estimate_media_ceiling(modality)
        :text -> text_read_projection(tc, ctx)
      end

    clamp_to_cap(projection, tc, ctx)
  end

  def read_file_projection(_, _ctx), do: summary_baseline_size() * @safety_padding

  # A `file-read` can never put more than the per-call inline cap inline: over
  # it, `BatchSizer.handle_over_cap/5` replaces the result with a small error —
  # for text and media alike (`media_over_cap_error/3`). So a projection above
  # the cap prices a result the tool is structurally unable to produce.
  #
  # Left unclamped, that projection can refuse a batch for a call that was
  # guaranteed to return a one-line error. The refusal is
  # conversation-independent — it is a property of the file, not of the
  # transcript — so compaction cannot clear it, and the same call is carried
  # across the commit and refused again. That is how a 3.3 MB PDF read, priced
  # at 1_002_423 tokens against a 1_048_576 window, produced an eight-round
  # compaction loop in which the model never learned why its call failed.
  #
  # The cap is `cook/2`'s own number: it reads `usable_remaining/1` once for the
  # whole batch and never advances it, so this clamp and the execution-time cap
  # cannot drift apart.
  #
  # A context with no usable window left (already at or past its content limit)
  # leaves the projection alone. The batch cannot fit whatever this returns —
  # the reserve alone already meets the limit — and
  # `CapCalculator.effective_max_result_tokens/2` requires a positive window, so
  # there is no cap to clamp to. `cook/2` reports the same window as no cap
  # (`cap_for/2`) and substitutes the result rather than raising.
  defp clamp_to_cap(projection, tc, ctx) do
    case CapCalculator.usable_window(ctx) do
      {:ok, usable} -> min(projection, CapCalculator.effective_max_result_tokens(tc, usable))
      :none -> projection
    end
  end

  # read_file projection: stat-then-cap, then estimate from byte
  # size. The actual read happens in Phase 2; preflight does the
  # cheaper stat so the batch can be refused before doing the read
  # work. The stat goes through `Nest.Sandbox` so the preflight
  # honors the same caps the read would, and resolves the path
  # against the workspace (an absolute path is used as-is). Any
  # failure falls back to the conservative summary size.
  defp text_read_projection(%ToolCall{} = tc, ctx) do
    with {:ok, full_path} <- resolved_read_path(tc, ctx),
         {:ok, size} <- stat_size_for(full_path, ctx) do
      # Estimate from the byte size alone. Synthesizing a same-size
      # string to feed the tokenizer is wasteful and pathological for
      # BPE tokenization (quadratic on repeated characters).
      Estimator.estimate_bytes(size)
    else
      _ -> summary_baseline_size() * @safety_padding
    end
  end

  def summary_baseline_size do
    estimator_overhead("[error placeholder]")
  end

  defp caps_of(ctx) do
    case Map.get(ctx, :caps) do
      %{} = caps -> caps
      _ -> Nest.Sandbox.default_caps()
    end
  end

  # Estimate the size of a small fixed-shape error string. The
  # 20% safety padding mirrors the public `BatchSizer.execute/2`
  # docstring — every projection is conservative.
  def estimator_overhead(text) do
    Estimator.estimate(text) * @safety_padding
  end

  # How many names an `agents-archive` call asks for. Clamped to at least one:
  # a call whose `name` is unusable still produces one error sentence, and this
  # is a bound, so it must never be zero.
  defp archive_name_count(%ToolCall{arguments: %{"name" => names}}) when is_list(names),
    do: max(length(names), 1)

  defp archive_name_count(_tc), do: 1
end

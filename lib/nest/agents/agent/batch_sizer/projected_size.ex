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

  alias Nest.Messages.ToolCall
  alias Nest.Sandbox
  alias Nest.Tokens.Estimator
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

  def project(%ToolCall{name: "agents-archive"}, _ctx),
    do: estimator_overhead("Archived agent clever-raven.")

  def project(%ToolCall{name: "agents-unarchive"}, _ctx),
    do: estimator_overhead("Restored agent clever-raven.")

  def project(%ToolCall{name: "agents-send"}, _ctx),
    do: estimator_overhead("Message queued for clever-raven.")

  def project(%ToolCall{name: "agents-wait-for-idle"}, _ctx),
    do: summary_baseline_size() * @safety_padding

  def project(%ToolCall{name: "agents-last-message"}, _ctx),
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
    agents-archive agents-unarchive agents-send agents-wait-for-idle agents-last-message
  )

  @doc false
  @spec projected?(String.t()) :: boolean()
  def projected?(name), do: name in @projected_tools

  @doc """
  Sum of `project/2` over `tool_calls`, sharing one `Sandbox.stat/4` per
  distinct resolved `file-read` path (issue #48).

  `BatchSizer.projected_content_size/2` and `preflight/2` both go through
  here, so a batch never stats the same file twice: the preflight's per-call
  stat used to be one bwrap spawn per `file-read` call.
  """
  @spec project_batch([ToolCall.t()], map()) :: number()
  def project_batch(tool_calls, ctx) when is_list(tool_calls) do
    ctx = Map.put(ctx, :file_read_sizes, read_file_sizes(tool_calls, ctx))
    Enum.reduce(tool_calls, 0, fn tc, acc -> acc + project(tc, ctx) end)
  end

  # ---- private helpers ----

  # The stat result for every distinct path a `file-read` call in this batch
  # targets. Keyed on the *resolved* path, so two spellings of one file share
  # a stat; spellings that resolve differently are statted separately (never a
  # wrong size, at most one extra spawn). `caps`, `workspace_path` and
  # `tmp_path` are constant across a `ctx`, so a memo hit is exactly what a
  # live `Sandbox.stat/4` would have returned.
  #
  # `Sandbox.stat_many/4` runs one `stat` invocation for the whole chunk of
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

    Sandbox.stat_many(
      paths,
      caps_of(ctx),
      Map.get(ctx, :workspace_path),
      Map.get(ctx, :tmp_path)
    )
  end

  # The path a `file-read` call targets, resolved against the workspace, or
  # `:error` for a malformed call / a relative path with no workspace. Shared
  # with `read_file_projection/2` so the memo can only ever hold paths the
  # projection would itself have statted.
  defp resolved_read_path(%ToolCall{arguments: args}, ctx) do
    with %{"path" => path} <- args,
         true <- is_binary(path) and path != "",
         {:ok, full_path} <- Sandbox.resolve(path, Map.get(ctx, :workspace_path)) do
      {:ok, full_path}
    else
      _ -> :error
    end
  end

  # The size of one resolved path: from the batch memo when the caller supplied
  # one (see `project_batch/2`), otherwise a live `Sandbox.stat/4`. A memo miss
  # still stats, so `project/2` on its own keeps its old behaviour.
  defp stat_size_for(full_path, ctx) do
    case Map.get(ctx, :file_read_sizes) do
      %{} = sizes -> Map.get_lazy(sizes, full_path, fn -> live_stat_size(full_path, ctx) end)
      _ -> live_stat_size(full_path, ctx)
    end
  end

  # `Sandbox.stat_many/4` returns sizes directly; `Sandbox.stat/4` returns a
  # partial `%File.Stat{}` of which the projection reads only `size`.
  #
  # `full_path` is the sandbox-domain path the agent used; `ctx.tmp_path` is a
  # HOST path passed only so the sandbox can resolve it. The host spelling must
  # never be shown to the LLM.
  defp live_stat_size(full_path, ctx) do
    case Sandbox.stat(
           full_path,
           caps_of(ctx),
           Map.get(ctx, :workspace_path),
           Map.get(ctx, :tmp_path)
         ) do
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
  # takes `text_read_projection/2` below, unchanged. Do not widen it.
  def read_file_projection(%ToolCall{arguments: %{"path" => path}} = tc, ctx)
      when is_binary(path) do
    case MediaKind.from_path(path) do
      {:ok, modality} -> Estimator.estimate_media_ceiling(modality)
      :text -> text_read_projection(tc, ctx)
    end
  end

  def read_file_projection(_, _ctx), do: summary_baseline_size() * @safety_padding

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
end

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

  @safety_padding 1.20

  # `agents-list` / `models-list` are hard-sliced to this many chars in
  # `Nest.Agents.Agent.ToolLoop`; their projection is bounded by it.
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

  def project(%ToolCall{name: name}, _ctx) when name in ["agents-list", "models-list"],
    do: Estimator.estimate_bytes(@max_list_chars)

  def project(%ToolCall{name: "agents-archive"}, _ctx),
    do: estimator_overhead("Archived agent clever-raven.")

  def project(%ToolCall{name: "agents-send"}, _ctx),
    do: estimator_overhead("Message queued for clever-raven.")

  def project(%ToolCall{name: "agents-wait"}, _ctx),
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
    agents-spawn agents-query agents-batch agents-list models-list agents-archive
    agents-send agents-wait
  )

  @doc false
  @spec projected?(String.t()) :: boolean()
  def projected?(name), do: name in @projected_tools

  # ---- private helpers ----

  # read_file projection: stat-then-cap, then estimate from byte
  # size. The actual read happens in Phase 2; preflight does the
  # cheaper stat so the batch can be refused before doing the read
  # work. The stat goes through `Nest.Sandbox` so the preflight
  # honors the same caps the read would, and resolves the path
  # against the workspace (an absolute path is used as-is). Any
  # failure falls back to the conservative summary size.
  def read_file_projection(%ToolCall{arguments: args} = _tc, ctx) do
    # `full_path` is the sandbox-domain path the agent used; `ctx.tmp_path`
    # is a HOST path passed only so `Sandbox.stat/3` can resolve it. The host
    # spelling must never be shown to the LLM.
    with %{"path" => path} <- args,
         true <- is_binary(path) and path != "",
         {:ok, full_path} <- Sandbox.resolve(path, Map.get(ctx, :workspace_path)),
         {:ok, %{size: size}} <-
           Sandbox.stat(
             full_path,
             caps_of(ctx),
             Map.get(ctx, :workspace_path),
             Map.get(ctx, :tmp_path)
           ) do
      # Estimate from the byte size alone. Synthesizing a same-size
      # string to feed the tokenizer is wasteful and pathological for
      # BPE tokenization (quadratic on repeated characters).
      Estimator.estimate_bytes(size)
    else
      _ -> summary_baseline_size() * @safety_padding
    end
  end

  def read_file_projection(_, _ctx), do: summary_baseline_size() * @safety_padding

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

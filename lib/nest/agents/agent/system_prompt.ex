defmodule Nest.Agents.Agent.SystemPrompt do
  @moduledoc """
  Composes the agent's initial system prompt from the
  vocation's base prompt and several contextual sections
  (mode catalog, `[mode: compact]` compaction guidance,
  workspace, tool-call budget, context limit, AGENTS.md).

  Extracted from `Nest.Agents.Agent` so the GenServer
  module stays under the 500-line credo limit. The
  resulting prompt becomes the `content` of the
  `{:system, _}` message at position 0 of the agent's
  messages list.

  The `[mode: compact]` paragraph is the SOLE source of
  compaction semantics in the agent's prompt. The
  compactor's per-call request appends a SUFFIX system
  message of the form `[mode: compact] Summarize the
  conversation in your <N> remaining tokens.`; the agent
  recognizes that prefix and follows the paragraph's
  guidance. Centralizing the guidance here means
  per-compaction input tokens are tiny (just the suffix)
  and we don't ship a separate "you are a summarizer"
  prompt template.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Tokens.Reserve
  alias Nest.Vocations

  @max_fraction_of_context 0.25

  # Conservative upper-bound token estimate used by the
  # `within_size_budget?/2` safety check. `chars / 3`
  # is more pessimistic than cl100k_base's typical ~4
  # chars/token — it accounts for code-heavy content
  # where individual characters are common tokens and
  # BPE expansions can balloon the count. We deliberately
  # don't use `Nest.Tokens.Estimator.estimate/1` here
  # because that calls the tiktoken NIF, which hangs or
  # panics on very large inputs (the NIF stack-overflows
  # on multi-MB strings). The safety check needs an
  # upper bound, not a precise count, so `chars / 3 +
  # overhead` is correct AND fast.
  @safety_chars_per_token 3
  @safety_overhead 10

  @doc """
  The token budget the safety check uses. Returns 0 for
  non-positive context limits (so the check trivially rejects
  an empty context).
  """
  @spec within_size_budget_budget(integer()) :: non_neg_integer()
  def within_size_budget_budget(context_limit)
      when is_integer(context_limit) and context_limit > 0 do
    div(context_limit, round(1 / @max_fraction_of_context))
  end

  def within_size_budget_budget(_), do: 0

  @doc """
  Returns true when `system_prompt` fits within the safety
  budget for `context_limit`.

  The budget is `#max_fraction_of_context` (`@max_fraction_of_context`)
  of `context_limit` — a belt-and-suspenders sanity check on
  top of the `compute_summary_budget/5` reserve logic. We
  refuse to produce a system prompt that would itself consume
  more than a quarter of the context window, even when the
  LLM could technically accept it (so the summary + system
  budget is guaranteed to fit).

  Uses `chars/3 + overhead` instead of
  `Nest.Tokens.Estimator.estimate/1` — see
  `@safety_chars_per_token` for why.

  `nil` returns `false` — the empty / no-system case is
  handled separately by the reserve-exhausted path, not by
  an "oversized" message.
  """
  @spec within_size_budget?(String.t() | nil, pos_integer()) :: boolean()
  def within_size_budget?(nil, _context_limit), do: false

  def within_size_budget?(system_prompt, context_limit)
      when is_binary(system_prompt) and is_integer(context_limit) and context_limit > 0 do
    upper_estimate(system_prompt) <= within_size_budget_budget(context_limit)
  end

  defp upper_estimate(text) when is_binary(text) do
    div(byte_size(text) + @safety_chars_per_token - 1, @safety_chars_per_token) + @safety_overhead
  end

  @doc """
  Compose the initial system prompt + mode + tool list from a
  pre-loaded `vocation` struct (or `nil`).

  No DB calls happen here — the caller is responsible for
  fetching the vocation before starting the agent. This keeps
  the agent's `init/1` free of `Repo` calls, which is what
  lets it run in async tests with `$callers` walking instead
  of per-pid `Sandbox.allow`.

  The `context_limit_info` argument is `{context_limit,
  context_limit_source}` from `Init.initial_context_limit/1`.
  Both fields are populated eagerly at startup (DotConfig
  first, then `Models.context_limit/2` cache, then a 128k
  `:default` floor), so the rendered prompt is always
  confident — the context-limit section is never omitted.

  The `name` argument is the agent's readable identifier; it
  is rendered into an identity line telling the agent its name
  and spawn depth. The `depth` argument is the agent's distance
  from its tree root (0 for roots, `parent.depth + 1` for
  children). The identity line reports `depth` of
  `Config.configured_max_depth/0`. Note: a clone inherits this
  system message from its parent, so the reported name/depth
  may be stale once cloned — the clone's own "You are the
  clone" notice supersedes it.
  """
  @spec compose_vocation_config(
          Nest.Vocations.Vocation.t() | nil,
          String.t() | nil,
          {integer() | nil, atom() | nil},
          String.t(),
          non_neg_integer()
        ) ::
          {String.t() | nil, String.t(), [String.t()], Nest.Vocations.Vocation.t() | nil}
  def compose_vocation_config(nil, _workspace_path, _context_limit_info, _name, _depth),
    do: {nil, "chat", [], nil}

  def compose_vocation_config(vocation, workspace_path, context_limit_info, name, depth) do
    initial_mode = get_initial_mode(vocation.modes)
    tools = vocation.tools || []

    system_prompt =
      (vocation.system_prompt || "") <>
        Vocations.mode_catalog(vocation) <>
        build_suffix(workspace_path, context_limit_info, name, depth) <>
        agents_md_section(workspace_path)

    {system_prompt, initial_mode, tools, vocation}
  end

  defp build_suffix(workspace_path, context_limit_info, name, depth) do
    identity_section(name, depth) <>
      workspace_section(workspace_path) <>
      tool_call_limit_section() <>
      context_limit_section(context_limit_info)
  end

  # Tell the agent its name and spawn depth. Non-clones and
  # clones at/after compaction get this in the system message.
  # A clone inherits this from its parent, so the "(may change
  # when cloned)" caveat warns that a future clone is a
  # different agent/depth; the clone's own fork notice carries
  # the corrected values.
  defp identity_section(name, depth) when is_binary(name) and name != "" do
    max_depth = Config.configured_max_depth()

    "\n\nYour name is \"#{name}\". You are at spawn depth #{depth} of #{max_depth}. " <>
      "That may change when cloned.\n"
  end

  defp identity_section(_name, _depth), do: ""

  defp workspace_section(nil), do: ""

  defp workspace_section(path),
    do: "\n\nWorkspace and tool working directory: #{path}\n"

  defp tool_call_limit_section do
    max = Config.configured_max_tool_iterations()

    "\n\nTool call budget: You have a maximum of #{max} consecutive tool call rounds per turn.\n"
  end

  # Renders the context-limit section. The limit is always
  # populated eagerly at startup (no async probe); the source
  # describes where the number came from (`:config` for
  # DotConfig, the provider shape that `Nest.Models` resolved
  # from the `/models` endpoint — `:vllm`, `:openrouter`,
  # `:olla`, `:llama_cpp` — or the `:default` 128k floor). The
  # `{nil, _}` clause is retained defensively for direct callers
  # that pass a nil limit explicitly.
  defp context_limit_section({nil, _}), do: ""

  defp context_limit_section({limit, source}) do
    reserve = Reserve.response_budget(limit)
    effective = max(1, limit - reserve)

    "\n\nContext limit: #{limit} tokens (resolved from #{source}). " <>
      "Of this, ~#{reserve} tokens are reserved for compaction, " <>
      "giving a working token budget of ~#{effective} tokens.\n"
  end

  defp agents_md_section(nil), do: ""

  defp agents_md_section(workspace_path) do
    case File.read(Path.join(workspace_path, "AGENTS.md")) do
      {:ok, content} ->
        "\n\nHere are AGENTS.md guidelines for this project:\n\n#{content}\n"

      _ ->
        ""
    end
  end

  defp get_initial_mode(nil), do: "chat"

  defp get_initial_mode(%{} = modes) when map_size(modes) > 0,
    do: modes |> Map.keys() |> List.first()

  defp get_initial_mode(_), do: "chat"
end

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
  first, then `Models.context_limit/2` cache) so the rendered
  prompt is always confident — there is no `:default`
  placeholder.

  The `depth` argument controls whether `clone_agent` is
  included in the tool list and rendered into the system
  prompt's delegation section. At `depth >= max_depth` the
  agent cannot spawn children, so the tool is filtered out
  and the section is omitted. Defaults to 0 (root agent).
  """
  @spec compose_vocation_config(
          Nest.Vocations.Vocation.t() | nil,
          String.t() | nil,
          {integer() | nil, atom() | nil},
          non_neg_integer()
        ) ::
          {String.t() | nil, String.t(), [String.t()], Nest.Vocations.Vocation.t() | nil}
  def compose_vocation_config(nil, _workspace_path, _context_limit_info, _depth),
    do: {nil, "chat", [], nil}

  def compose_vocation_config(vocation, workspace_path, context_limit_info, depth) do
    initial_mode = get_initial_mode(vocation.modes)
    max_depth = Config.configured_max_depth()
    tools = filter_tools_for_depth(vocation.tools || [], depth, max_depth)

    system_prompt =
      (vocation.system_prompt || "") <>
        Vocations.mode_catalog(vocation) <>
        build_suffix(workspace_path, context_limit_info, depth, max_depth, tools)

    {system_prompt, initial_mode, tools, vocation}
  end

  # The `clone_agent` tool is only included when the agent
  # can still spawn children. Roots (depth 0) and intermediate
  # nodes (depth < max_depth) get the tool; leaves at max
  # depth do not. Non-clone_agent tools pass through unchanged.
  defp filter_tools_for_depth(tool_names, depth, max_depth)
       when is_integer(depth) and depth < max_depth do
    tool_names
  end

  defp filter_tools_for_depth(tool_names, _depth, _max_depth) do
    Enum.reject(tool_names, &(&1 == "clone_agent"))
  end

  defp build_suffix(workspace_path, context_limit_info, depth, max_depth, tools) do
    workspace_section(workspace_path) <>
      tool_call_limit_section() <>
      context_limit_section(context_limit_info) <>
      delegation_section(depth, max_depth, tools) <>
      agents_md_section(workspace_path)
  end

  defp workspace_section(nil), do: ""

  defp workspace_section(path),
    do: "\n\nWorkspace and tool working directory: #{path}\n"

  defp tool_call_limit_section do
    max = Config.configured_max_tool_iterations()

    "\n\nTool call budget: You have a maximum of #{max} consecutive tool call rounds per turn.\n"
  end

  # Renders the context-limit section. The limit is always
  # populated eagerly at startup (no async probe, no
  # `:default` placeholder); the source describes where the
  # number came from (`:config` for DotConfig, or the
  # provider shape that `Nest.Models` resolved from the
  # `/models` endpoint — `:vllm`, `:openrouter`,
  # `:llama_cpp`).
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

  # Renders the `[Delegation]` section in the system prompt when
  # the agent has any sub-agent tool available (`clone_agent`,
  # `spawn_agent`, `list_agents`). Each tool that is present in
  # the filtered tool list gets its own paragraph explaining its
  # semantics. `clone_agent` is depth-filtered separately (see
  # `filter_tools_for_depth/3`), so an agent at max depth that
  # only has `clone_agent` gets no section at all — matching the
  # pre-Phase-3 contract.
  defp delegation_section(depth, max_depth, tools) do
    paragraphs =
      [
        clone_delegation(depth, max_depth, tools),
        spawn_delegation(tools),
        query_delegation(tools),
        list_delegation(tools)
      ]
      |> Enum.reject(&(&1 == ""))

    case paragraphs do
      [] -> ""
      _ -> "\n\n[Delegation]\n\n" <> Enum.join(paragraphs, "\n\n") <> "\n"
    end
  end

  defp clone_delegation(depth, max_depth, tools)
       when is_integer(depth) and is_integer(max_depth) and depth < max_depth do
    if "clone_agent" in tools do
      remaining = max_depth - depth - 1
      chain = if remaining == 0, do: "one more level", else: "#{remaining} more levels"

      "You have access to the `clone_agent` tool. " <>
        "Calling it spawns a child agent with a copy of this conversation " <>
        "(your full message history including the system prompt) plus the " <>
        "instruction as a new user message. The child runs to completion " <>
        "before the result is returned to you — your chat turn blocks " <>
        "until the child goes idle. The child's final assistant message " <>
        "content is delivered to you as the tool result; use it as your " <>
        "answer or to drive further tool calls.\n\n" <>
        "Children can call `clone_agent` themselves up to #{chain} of " <>
        "recursion (current depth #{depth}, max #{max_depth}). " <>
        "Children inherit your context, so their first call sends a large " <>
        "message list — keep that in mind when delegating deep conversations."
    else
      ""
    end
  end

  defp clone_delegation(_depth, _max_depth, _tools), do: ""

  defp spawn_delegation(tools) do
    if "spawn_agent" in tools do
      "You have access to the `spawn_agent` tool. " <>
        "Calling it creates an independent sub-agent in this space with a " <>
        "fresh context (only its system prompt — no conversation history). " <>
        "It runs independently and does not block your turn. Pass a unique " <>
        "`name` and a `vocation_id` (list the space's vocations if unsure). " <>
        "This is how you assemble a team of specialists that you can later " <>
        "talk to."
    else
      ""
    end
  end

  defp query_delegation(tools) do
    if "query_agent" in tools do
      "You have access to the `query_agent` tool. Calling it sends a message " <>
        "to a sub-agent in this space and blocks your turn until that agent " <>
        "responds, returning its reply as the tool result. Use it to ask a " <>
        "specialist (spawned via `spawn_agent`) to do work on your behalf."
    else
      ""
    end
  end

  defp list_delegation(tools) do
    if "list_agents" in tools do
      "You have access to the `list_agents` tool. Calling it returns the " <>
        "sub-agents running in this space, with their name, vocation, " <>
        "status, and depth. Use it to discover which specialists already " <>
        "exist before spawning new ones."
    else
      ""
    end
  end

  defp get_initial_mode(nil), do: "chat"

  defp get_initial_mode(%{} = modes) when map_size(modes) > 0,
    do: modes |> Map.keys() |> List.first()

  defp get_initial_mode(_), do: "chat"
end

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
  alias Nest.Scripts.CompactionProbeSupport
  alias Nest.Tokens.Reserve
  alias Nest.Vocations

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
  """
  @spec compose_vocation_config(
          Nest.Vocations.Vocation.t() | nil,
          String.t() | nil,
          {integer() | nil, atom() | nil}
        ) ::
          {String.t() | nil, String.t(), [String.t()], Nest.Vocations.Vocation.t() | nil}
  def compose_vocation_config(nil, _workspace_path, _context_limit_info),
    do: {nil, "chat", [], nil}

  def compose_vocation_config(vocation, workspace_path, context_limit_info) do
    initial_mode = get_initial_mode(vocation.modes)
    tools = vocation.tools || []

    system_prompt =
      (vocation.system_prompt || "") <>
        Vocations.mode_catalog(vocation) <>
        build_suffix(workspace_path, context_limit_info)

    {system_prompt, initial_mode, tools, vocation}
  end

  defp build_suffix(workspace_path, context_limit_info) do
    workspace_section(workspace_path) <>
      tool_call_limit_section() <>
      context_limit_section(context_limit_info) <>
      agents_md_section(workspace_path) <>
      compaction_mode_section()
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

  # The [mode: compact] paragraph is the agent's full
  # compaction semantic guidance. The compactor's per-call
  # request appends a SUFFIX system message:
  #
  #   [mode: compact] Summarize the conversation in your
  #   <N> remaining tokens. {optional_guidance}
  #
  # The agent recognizes the `[mode: compact]` prefix and
  # follows the guidance below to produce a bounded
  # head_summary that replaces the prior conversation.
  #
  # Single source of truth: the same paragraph is rendered
  # here AND centralized in `CompactionProbeSupport.compaction_mode_section/0`
  # so the live prompt and the recovery script agree.
  @doc """
  The compact-mode paragraph as it's rendered into the agent's
  initial system prompt. Exposed so tests can pin the exact
  wording.
  """
  @spec compaction_mode_section() :: String.t()
  def compaction_mode_section, do: CompactionProbeSupport.compaction_mode_section()

  defp get_initial_mode(nil), do: "chat"

  defp get_initial_mode(%{} = modes) when map_size(modes) > 0,
    do: modes |> Map.keys() |> List.first()

  defp get_initial_mode(_), do: "chat"
end

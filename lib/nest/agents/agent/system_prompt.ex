defmodule Nest.Agents.Agent.SystemPrompt do
  @moduledoc """
  Composes the agent's initial system prompt from the
  vocation's base prompt and several contextual sections
  (the universal modes, the `[mode: compact]` compaction
  contract, workspace, network access, tool-call budget,
  context limit, AGENTS.md).

  Extracted from `Nest.Agents.Agent` so the GenServer
  module stays under the 500-line credo limit. The
  resulting prompt becomes the `content` of the
  `{:system, _}` message at position 0 of the agent's
  messages list.

  The `[mode: compact]` paragraph is the SOLE source of
  compaction semantics in the agent's prompt. The
  compactor's per-call request appends a SUFFIX system
  message of the form `[mode: compact]\nSummarize the
  conversation in your <N> remaining tokens.`; the agent
  recognizes that prefix and follows the paragraph's
  guidance. Centralizing the guidance here means
  per-compaction input tokens are tiny (just the suffix)
  and we don't ship a separate "you are a summarizer"
  prompt template.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Messages.Sanitize
  alias Nest.Modes
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.Reserve
  alias Nest.Tools.Groups
  alias Nest.Vocations

  @max_fraction_of_context 0.25

  # Conservative upper-bound token estimate used by the
  # `within_size_budget?/2` safety check. `chars / 3`
  # is more pessimistic than cl100k_base's typical ~4
  # chars/token — it accounts for code-heavy content
  # where individual characters are common tokens and
  # BPE expansions can balloon the count. We deliberately
  # don't use `Nest.Tokens.Estimator.estimate/1` here
  # because that calls the tokenizer, which is slow and
  # stack-risky on very large inputs (multi-MB strings).
  # The safety check needs an upper bound, not a precise
  # count, so `chars / 3 + overhead` is correct AND fast.
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
  It takes no `mode`. The modes are universal (`Nest.Modes`) and an agent's
  mode is a runtime property, so the composer renders the constant catalog and
  states the mode nowhere: every message already states it. The `AGENTS.md` read
  used to be authorized with the mode's caps and is now a host read, which is
  why the argument went away rather than becoming unused.
  """
  @spec compose_vocation_config(
          Nest.Vocations.Vocation.t() | nil,
          Mounts.t(),
          {integer() | nil, atom() | nil},
          String.t(),
          non_neg_integer()
        ) ::
          {String.t() | nil, [String.t()], Nest.Vocations.Vocation.t() | nil}
  def compose_vocation_config(nil, _mounts, _context_limit_info, _name, _depth),
    do: {nil, [], nil}

  def compose_vocation_config(vocation, mounts, context_limit_info, name, depth) do
    tools = Groups.expand(vocation.tools || [])

    system_prompt =
      (vocation.system_prompt || "") <>
        modes_section(tools, mounts) <>
        build_suffix(mounts, context_limit_info, name, depth, tools) <>
        agents_md_section(mounts) <>
        Nest.ProjectConfig.section(Mounts.workspace(mounts))

    {system_prompt, tools, vocation}
  end

  # The universal modes, plus the compaction contract.
  #
  # The modes themselves are a constant (`Nest.Modes.catalog/2`), and the section
  # is *empty* for an agent with no tools: with nothing to call there is nothing
  # for a mode to restrict, so it would describe a distinction the agent cannot
  # act on. The `compact` contract is not about modes and a tool-less agent still
  # compacts, so it is rendered either way — inside the same `[Available modes]`
  # marker it has always been in, which is what the runtime's `[mode: compact]`
  # suffix refers to.
  #
  # `enforced?` is the space's, not the agent's: a `"none"` space has no sandbox
  # to enforce the restriction with, so the text has to say so rather than claim
  # a write will fail.
  defp modes_section(tools, mounts) do
    tool_capable? = tools != []
    enforced? = Mounts.backend(mounts) != "none"

    Modes.catalog(tool_capable?, enforced?) <>
      modes_marker(tool_capable?) <>
      "- compact: #{Vocations.compact_description()}\n"
  end

  # With modes to list, `Nest.Modes.catalog/2` already opened the section.
  defp modes_marker(true), do: ""

  defp modes_marker(false), do: "\n\n[Available modes]\n\n"

  defp build_suffix(mounts, context_limit_info, name, depth, tools) do
    identity_section(name, depth) <>
      tool_sections(tools, mounts, name) <>
      context_limit_section(context_limit_info)
  end

  # Every prompt section that only makes sense when the agent can call
  # tools: the agent's own scratch directory (reached with `file-*` /
  # `shell-cmd`), the workspace/tool working directory, the space's network
  # access and the tool-call budget. Gathered here so a tool-less vocation
  # (e.g. Chat) gets a prompt with no dangling tool references — it cannot
  # reach a scratch directory or the network, so telling it about either
  # would be a dangling reference too.
  #
  # Ordering is load-bearing for the prompt's bytes: the scratch sentence
  # follows the identity line, then the working directory, then the network.
  defp tool_sections([], _mounts, _name), do: ""

  defp tool_sections(_tools, mounts, name),
    do:
      scratch_section(name) <>
        workspace_section(Mounts.workspace(mounts)) <>
        network_section(mounts) <>
        tool_call_limit_section()

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

  # Tell the agent where its own scratch directory is. The space directory
  # is bound at `/tmp` inside the sandbox, so the agent's own directory is
  # `/tmp/<agent-name>`. The directory that bind is made from is internal to
  # `Nest.Sandbox` and is never named to the agent.
  #
  # Emitted only for a tool-capable vocation (see `tool_sections/3`): the
  # directory is reached with `file-*` / `shell-cmd`, so a tool-less
  # vocation has no use for it.
  #
  # This is stated HERE, once, rather than in the description of every
  # path-taking tool: the tool schemas and the system message are both
  # prefix-cache-visible, and repeating the sentence in six descriptions
  # bought nothing. A clone inherits its ancestor's system message
  # verbatim (see `identity_section/2`), so `MessageList.clone_notice/2`
  # states the clone's own directory — its tools no longer do.
  defp scratch_section(name) when is_binary(name) and name != "" do
    "\n\nYour own scratch directory is `#{Sandbox.scratch_dir(name)}/`; the `/tmp` root is shared " <>
      "with your siblings in this space, so put anything that must not be clobbered " <>
      "under your own directory.\n"
  end

  defp scratch_section(_name), do: ""

  defp workspace_section(nil), do: ""

  defp workspace_section(path),
    do: "\n\nWorkspace and tool working directory: #{path}\n"

  # Whether the agent can reach the network is a *space* property, not a mode's:
  # it is resolved once at agent start and carried on the mounts
  # (`Nest.Spaces.network_access`), and `Nest.Sandbox` injects it as the call's
  # `"net"` cap. It is stated here, next to the other tool-gated lines, rather
  # than in the modes section, so it is said once and only to an agent that can
  # act on it — a tool-less agent has no command that could reach the network.
  #
  # It is a property of the agent and its space, so the bytes are the same on
  # every composition for a given agent, which is what keeps the system message
  # cache-safe.
  #
  # A `"none"` space has no sandbox, so the setting cannot be enforced there:
  # the sentence has to say so rather than claim a restriction that does not
  # exist (`Nest.Sandbox.Backend.None`'s caps are unenforceable by
  # construction — see `notes/sandbox-backends.md`).
  defp network_section(mounts) do
    "\n\n" <> network_sentence(Mounts.backend(mounts), Mounts.network_access(mounts))
  end

  defp network_sentence("none", network_access) do
    "Network access is #{network_word(network_access)} for this space, but this space " <>
      "has no sandbox to enforce it: your commands can reach the network either way.\n"
  end

  defp network_sentence(_backend, true) do
    "Network access is enabled for this space: your commands can reach the network.\n"
  end

  defp network_sentence(_backend, false) do
    "Network access is disabled for this space: the sandbox blocks your commands " <>
      "from reaching the network.\n"
  end

  defp network_word(true), do: "enabled"
  defp network_word(false), do: "disabled"

  defp tool_call_limit_section do
    max = Config.configured_max_tool_iterations()

    "\n\nTool call budget: You have a maximum of #{max} consecutive tool call rounds per turn.\n"
  end

  # Renders the context-limit section. The limit is always
  # populated eagerly at startup (no async probe); the source
  # describes where the number came from (`:config` for
  # DotConfig, the provider shape that `Nest.Models` resolved
  # from the `/models` endpoint — `:vllm`, `:openrouter`,
  # `:context_window`, `:olla`, `:llama_cpp` — or the
  # `:default` 128k floor). The `{nil, _}` clause is retained
  # defensively for direct callers that pass a nil limit
  # explicitly.
  defp context_limit_section({nil, _}), do: ""

  defp context_limit_section({limit, source}) do
    reserve = Reserve.compaction_reserve(limit)
    effective = max(1, limit - reserve)

    "\n\nContext limit: #{limit} tokens (resolved from #{source}). " <>
      "Of this, ~#{reserve} tokens are reserved for compaction, " <>
      "giving a working token budget of ~#{effective} tokens.\n"
  end

  defp agents_md_section(%Mounts{workspace: nil}), do: ""

  defp agents_md_section(mounts) do
    # `AGENTS.md` lives at the workspace root and is read on the **host**, the
    # same way `Nest.ProjectConfig.load/1` reads `.nest` for the section
    # rendered just above. Both files are masked read-only into the sandbox by
    # `Nest.ProjectConfig.protected_entries/1` — *when they are regular files* —
    # so an agent's view at that path is the host file, by construction.
    #
    # Reading it through the sandbox instead would buy nothing and cost a
    # `bwrap` fork per agent start (measured at ~9ms, ~1.5s of the suite). It
    # was never the read set doing the work either: both modes have
    # `fs.read: ["/"]`, so the caps could not have refused it.
    path = Path.join(Mounts.workspace(mounts), Nest.ProjectConfig.agents_md_name())

    case Nest.ProjectConfig.read_config_file(path) do
      {:ok, content} ->
        agents_md_block(content)

      # Unreachable: `Nest.ProjectConfig.config_file_error/1` refuses a workspace
      # whose `AGENTS.md` is not a regular file, so no agent starts in one. The
      # clause is here because `read_config_file/1` is total.
      {:not_regular, _type} ->
        ""

      # A regular file the OS will not let us read. Silent, unlike `.nest`'s
      # visible error section: `.nest` *grants* things, so a `.nest` we cannot
      # read must be loud, whereas `AGENTS.md` only states policy — an unreadable
      # one leaves the prompt with less guidance, not with a wrong claim.
      {:error, _reason} ->
        ""

      :absent ->
        ""
    end
  end

  defp agents_md_block(content) do
    # The file is arbitrary user bytes: NUL / invalid UTF-8 cannot be
    # stored in the system message's jsonb row. Replace them rather
    # than crash the Agent.
    "\n\nHere are AGENTS.md guidelines for this project:\n\n#{Sanitize.text(content)}\n"
  end
end

defmodule Nest.Agents.Agent.SystemPrompt do
  @moduledoc """
  Composes the agent's initial system prompt from the
  vocation's base prompt and several contextual sections
  (mode catalog, workspace, tool-call budget, context limit,
  AGENTS.md).

  Extracted from `Nest.Agents.Agent` so the GenServer
  module stays under the 500-line credo limit. The
  resulting prompt becomes the `content` of the
  `{:system, _}` message at position 0 of the agent's
  messages list.
  """

  alias Nest.Vocations

  @doc """
  Resolve the vocation record (if a `vocation_id` was
  provided) and return the tuple
  `{system_prompt, initial_mode, tool_names, vocation}`. When
  no vocation is provided (or the record is missing), returns
  `{nil, "chat", [], nil}`.

  The `context_limit_info` argument is `{context_limit,
  context_limit_source}` from `Init.initial_context_limit/1`.
  When the limit is `nil` (no model configured, no probe
  pending), the context-limit section is omitted from the
  prompt. When the source is `:default` (the 128k fallback
  before the async probe completes), the section is included
  with a "default" caveat so the LLM knows the number is
  provisional.
  """
  @spec fetch_vocation_config(integer() | nil, String.t() | nil, {integer() | nil, atom() | nil}) ::
          {String.t() | nil, String.t(), [String.t()], Nest.Vocations.Vocation.t() | nil}
  def fetch_vocation_config(nil, _workspace_path, _context_limit_info),
    do: {nil, "chat", [], nil}

  def fetch_vocation_config(vocation_id, workspace_path, context_limit_info) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        {nil, "chat", [], nil}

      vocation ->
        initial_mode = get_initial_mode(vocation.modes)
        tools = vocation.tools || []

        system_prompt =
          (vocation.system_prompt || "") <>
            Vocations.mode_catalog(vocation) <>
            build_suffix(workspace_path, context_limit_info)

        {system_prompt, initial_mode, tools, vocation}
    end
  end

  defp build_suffix(workspace_path, context_limit_info) do
    workspace_section(workspace_path) <>
      tool_call_limit_section() <>
      context_limit_section(context_limit_info) <>
      agents_md_section(workspace_path)
  end

  defp workspace_section(nil), do: ""

  defp workspace_section(path),
    do: "\n\nWorkspace and tool working directory: #{path}\n"

  defp tool_call_limit_section do
    max = Nest.Agents.Agent.configured_max_tool_iterations()

    "\n\nTool call budget: You have a maximum of #{max} consecutive tool call rounds per turn.\n"
  end

  # Renders the context-limit section. Three cases:
  #   - nil limit (no model, no probe pending)  -> omit
  #   - :default source (128k fallback)          -> "default" caveat
  #   - :configured or :probed source            -> confident value
  # The async probe may later overwrite the default; the LLM is
  # told via mid-iteration reminders when usage crosses 25/50/75%
  # of the *current* limit (the live one, not this static one).
  defp context_limit_section({nil, _}), do: ""

  defp context_limit_section({limit, :default}) do
    "\n\nContext limit: ~#{limit} tokens (default; the actual limit " <>
      "may differ after the model's limit is resolved).\n"
  end

  defp context_limit_section({limit, source}) do
    "\n\nContext limit: #{limit} tokens (resolved from #{source}). " <>
      "You can check current usage via the `context` tool " <>
      "(action: \"check\") and trigger compaction via the `context` " <>
      "tool (action: \"compact\").\n"
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

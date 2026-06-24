defmodule Nest.Agents.Agent.SystemPrompt do
  @moduledoc """
  Composes the agent's initial system prompt from the
  vocation's base prompt and several contextual sections
  (mode catalog, workspace, tool-call budget, AGENTS.md).

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
  """
  @spec fetch_vocation_config(integer() | nil, String.t() | nil) ::
          {String.t() | nil, String.t(), [String.t()], Nest.Vocations.Vocation.t() | nil}
  def fetch_vocation_config(nil, _workspace_path), do: {nil, "chat", [], nil}

  def fetch_vocation_config(vocation_id, workspace_path) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        {nil, "chat", [], nil}

      vocation ->
        initial_mode = get_initial_mode(vocation.modes)
        tools = vocation.tools || []

        system_prompt =
          (vocation.system_prompt || "") <>
            Vocations.mode_catalog(vocation) <>
            build_suffix(workspace_path)

        {system_prompt, initial_mode, tools, vocation}
    end
  end

  defp build_suffix(workspace_path) do
    workspace_section(workspace_path) <>
      tool_call_limit_section() <>
      agents_md_section(workspace_path)
  end

  defp workspace_section(nil), do: ""

  defp workspace_section(path),
    do: "\n\nWorkspace and tool working directory: #{path}\n"

  defp tool_call_limit_section do
    max = Nest.Agents.Agent.configured_max_tool_iterations()

    "\n\nTool call budget: You have a maximum of #{max} consecutive tool call rounds per turn.\n"
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

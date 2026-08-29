defmodule Nest.Agents.Agent.WorkspaceHandler do
  @moduledoc """
  `handle_call/3` clauses for changing an agent's working directory
  (`{:set_workspace, _}`) and the workspace half of the combined
  `{:edit_agent, _, _}` edit.

  Changing the workspace retargets the file/shell tool closures (they
  capture `workspace_path` at build time), so `state.tools` is rebuilt
  via `Tools.get_functions/3`. The persisted system prompt (index 0) is
  left untouched to preserve the LLM prefix cache; instead a
  user/assistant notice pair is appended (after a compaction preflight
  check) so the model learns the new working directory without a
  system-message re-render.

  When preflight decides the conversation needs compaction, the notice
  insertion is deferred: `state.live.pending_notice` is set and the
  compactor is triggered; on success `ChatPipeline.resume_pending_notice/1`
  appends the pair without an LLM request.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction.Trigger
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Tools

  @doc """
  Standalone workspace change. Dispatched from `IntrospectionHandler`.
  """
  @spec handle({:set_workspace, String.t() | nil}, GenServer.from(), Agent.t()) ::
          GenServer.reply()
  def handle({:set_workspace, path}, _from, state) do
    if state.live.status in [:idle, :model_missing] do
      perform_workspace_change(state, normalize(path))
    else
      {:reply, {:error, :agent_busy}, state}
    end
  end

  # Validate → persist → mutate → broadcast → reply. Returns the
  # GenServer reply tuple so the pipeline reads straight-line.
  defp perform_workspace_change(state, path) do
    case Persistence.update_agent_workspace(state.space_id, state.name, path) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        {state, _reply} = apply_workspace(state, path)
        Broadcasts.status(state)
        {:reply, :ok, state}
    end
  end

  @doc """
  Apply a workspace change to `state`. Does **not** persist or broadcast
  (the caller owns those). Rebuilds `state.tools`, resets the `read_files`
  cache, and appends the notice pair after a compaction preflight check.

  Returns `{state, :ok}` when the notice is inserted immediately, or
  `{state, :ok}` with `state.live.pending_notice` set and compaction
  triggered when preflight decides the conversation needs compaction, or
  `{state, {:error, :context_overflow}}` when compaction is impossible.
  """
  @spec apply_workspace(Agent.t(), String.t() | nil) ::
          {Agent.t(), :ok | {:error, :context_overflow}}
  def apply_workspace(state, path) do
    tools = Tools.get_functions(tool_names(state), path, state.tmp_path)

    state = %{
      state
      | workspace_path: path,
        tools: tools,
        chat_state: %{state.chat_state | read_files: %{}}
    }

    case preflight_decision(state) do
      :fits -> insert_notice_now(state)
      :needs_compaction -> {defer_notice_via_compaction(state), :ok}
      :cannot_compact -> {clear_pending_notice(state), {:error, :context_overflow}}
    end
  end

  @doc """
  Append the pending workspace notice pair (no LLM request) and clear
  `pending_notice`. Used by `ChatPipeline.resume_pending_notice/1` after a
  workspace-triggered compaction.
  """
  @spec resume_notice(Agent.t()) :: Agent.t()
  def resume_notice(state) do
    case state.live.pending_notice do
      nil -> state
      _path -> elem(insert_notice_now(state), 0)
    end
  end

  @doc """
  The notice user/assistant pair appended when the workspace changes.
  """
  @spec notice_pair(String.t() | nil) :: [Agent.message()]
  def notice_pair(path) do
    [
      {:user,
       %User{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: "[mode: notice]\nWorkspace changed to: #{path}"}],
         metadata: %{"mode" => "notice"},
         api_logs: []
       }},
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: "Workspace directory change confirmed."}],
         api_logs: []
       }}
    ]
  end

  defp insert_notice_now(state) do
    state =
      Enum.reduce(notice_pair(state.workspace_path), state, fn msg, acc ->
        {_stamped, acc} = Agent.__append_message__(acc, msg)
        acc
      end)

    {clear_pending_notice(state), :ok}
  end

  defp defer_notice_via_compaction(state) do
    state = %{state | live: %{state.live | pending_notice: state.workspace_path}}
    Trigger.post_turn(state)
  end

  defp clear_pending_notice(state) do
    %{state | live: %{state.live | pending_notice: nil}}
  end

  defp preflight_decision(state) do
    projected = state.chat_state.messages ++ notice_pair(state.workspace_path)
    ChatPipeline.preflight_decision(projected, state)
  end

  defp tool_names(state) do
    (state.vocation && state.vocation.tools) || []
  end

  defp normalize(nil), do: nil
  defp normalize(""), do: nil
  defp normalize(path), do: path
end

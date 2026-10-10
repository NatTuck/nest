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
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolFilter
  alias Nest.Agents.Agent.Turn
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Tools
  alias Nest.Tools.Groups

  require Logger

  @doc """
  Standalone workspace change. Dispatched from `IntrospectionHandler`.
  """
  @spec handle({:set_workspace, String.t() | nil}, GenServer.from(), Agent.t()) ::
          GenServer.reply()
  def handle({:set_workspace, path}, _from, state) do
    if Machine.status_for(state.live.machine) in [:idle, :model_missing] do
      perform_workspace_change(state, normalize(path))
    else
      {:reply, {:error, :agent_busy}, state}
    end
  end

  # Validate → persist → mutate → broadcast → reply. Returns the
  # GenServer reply tuple so the pipeline reads straight-line.
  defp perform_workspace_change(state, path) do
    with :ok <- Nest.Sandbox.workspace_error(path),
         :ok <- Persistence.update_agent_workspace(state.space_id, state.name, path) do
      {state, _reply} = apply_workspace(state, path)
      Broadcasts.status(state)
      {:reply, :ok, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

    state = %{
      state
      | live: %{
          state.live
          | machine: %{
              state.live.machine
              | work: %{state.live.machine.work | pending_notice: path}
            }
        }
    }

    {:ok, state} = Turn.settle(state, :workspace_notice)

    if Machine.status_for(state.live.machine) == :context_overflow do
      {state, {:error, :context_overflow}}
    else
      {state, :ok}
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

  defp tool_names(state) do
    tools = if state.vocation, do: state.vocation.tools, else: []

    (tools || [])
    |> Groups.expand()
    |> ToolFilter.exclude_spawn_at_max_depth(state.depth)
  end

  defp normalize(nil), do: nil
  defp normalize(""), do: nil
  defp normalize(path), do: path
end

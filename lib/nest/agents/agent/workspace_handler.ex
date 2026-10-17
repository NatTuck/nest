defmodule Nest.Agents.Agent.WorkspaceHandler do
  @moduledoc """
  Applies a change to the **space's** environment on a live agent.

  A workspace, a sandbox backend and a network access are all space properties
  (`Nest.Spaces.Space`), and an agent's `Nest.Sandbox.Mounts` is built from them
  once at start. So a change to any of them has to *reach* the agent: the mounts
  move, and the file/shell tool closures — which capture the mounts at build time
  — are rebuilt from the same tool names.

  The persisted system prompt (index 0) is deliberately left untouched to
  preserve the LLM prefix cache, so the prompt's own sentences about the
  workspace, the backend and the network are stale from here on. The change is
  therefore *announced* instead: a user/assistant notice pair stating the space's
  current environment, appended after a compaction preflight check. It is a
  reconciliation rather than a delta — it names the values now in force, so two
  edits in a row cannot leave the agent holding a partial picture.

  When preflight decides the conversation needs compaction, the insertion is
  deferred: `state.live.pending_notice` carries the values and the compactor is
  triggered; on success `Machine.Compaction.resume/1` appends the pair without an
  LLM request.

  ## Naming

  The module is still `WorkspaceHandler` and the machine event is still
  `:workspace_notice`, because both predate the workspace becoming a space
  property and renaming them means touching the machine's event vocabulary and
  its audit tables. The rename belongs with the caller that drives this — the
  space edit — not with the removal of the per-agent column.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolFilter
  alias Nest.Agents.Agent.Turn
  alias Nest.Messages.Assistant
  alias Nest.Messages.NoticeTag
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Sandbox.Mounts
  alias Nest.Tools
  alias Nest.Tools.Groups

  @typedoc """
  The space properties an agent's mounts carry, and that its prompt states: the
  workspace it binds, whether it may reach the network, and the backend that runs
  its commands.
  """
  @type values :: %{
          required(:workspace) => String.t() | nil,
          required(:network_access) => boolean(),
          required(:backend) => String.t()
        }

  @doc """
  Apply a space-environment change to `state`.

  Does **not** persist or broadcast: the space row is the truth, and this only
  moves the agent's copy of it. The caller owns the row write and the status
  broadcast.

  Returns `{state, :ok}` when the notice is inserted immediately, or
  `{state, :ok}` with `state.live.pending_notice` set and compaction triggered
  when preflight decides the conversation needs compaction, or
  `{state, {:error, :context_overflow}}` when compaction is impossible.
  """
  @spec apply_space_environment(Agent.t(), values()) ::
          {Agent.t(), :ok | {:error, :context_overflow}}
  def apply_space_environment(state, values) do
    names = tool_names(state)

    state = %{
      state
      | mounts: %{
          state.mounts
          | workspace: values.workspace,
            network_access: values.network_access,
            backend: values.backend
        },
        chat_state: %{state.chat_state | read_files: %{}}
    }

    state = %{state | tools: Tools.get_functions(names, Mounts.from_agent(state))}

    state = %{
      state
      | live: %{
          state.live
          | machine: %{
              state.live.machine
              | work: %{state.live.machine.work | pending_notice: values}
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
  The notice user/assistant pair appended when the space's environment changes.

  The user row is the runtime speaking — it is a notice, not the human's words
  — so it carries the `[nest notice]` marker after its `[mode: notice]` prefix
  (the client strips both on render). The assistant row is the acknowledgement,
  which is never tagged.
  """
  @spec notice_pair(values()) :: [Agent.message()]
  def notice_pair(values) do
    [
      {:user,
       %User{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: "[mode: notice]\n" <> NoticeTag.tag(body(values))}],
         metadata: %{"mode" => "notice"},
         api_logs: []
       }},
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: "Space environment change confirmed."}],
         api_logs: []
       }}
    ]
  end

  # One sentence per property, naming the values now in force. A single line
  # rather than a bulleted list because it is a notice, not a document.
  defp body(values) do
    "This space's environment changed. Workspace: #{values.workspace || "(none)"}. " <>
      "Network access: #{if values.network_access, do: "enabled", else: "disabled"}. " <>
      "Sandbox: #{values.backend}."
  end

  defp tool_names(state) do
    tools = if state.vocation, do: state.vocation.tools, else: []

    (tools || [])
    |> Groups.expand()
    |> ToolFilter.exclude_spawn_at_max_depth(state.depth)
  end
end

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

  @typedoc """
  What the apply did with the notice.

    * `:appended` — the pair is in the transcript now;
    * `:deferred` — preflight decided the conversation needs compaction, so the
      values are staged in `state.live.pending_notice` and
      `Machine.Compaction.resume/1` appends the pair when the commit lands;
    * `{:ignored, phase}` — the machine is mid-turn, so the `:workspace_notice`
      transition has nowhere to land (it is `:idle`-only) and nothing is staged
      or appended. The caller must leave `space_notice_pending` set: the agent
      then announces the change when it next starts;
    * `{:error, status}` — the machine blocked instead of delivering: the
      conversation cannot hold the pair and cannot be compacted either
      (`:context_overflow`), or the compaction it would need could not start.
      Nothing is appended, and the caller must leave the flag set.
  """
  @type outcome :: :appended | :deferred | {:ignored, Machine.phase()} | {:error, atom()}

  @doc """
  Apply a space-environment change to `state`.

  Does **not** persist or broadcast: the space row is the truth, and this only
  moves the agent's copy of it. The caller owns the row write and the status
  broadcast.

  The **mounts and the tool closures move whatever the outcome**: a command the
  agent runs next has to use the space's current values, and that half needs no
  machine. Only the *notice* is conditional, and the outcome says what happened
  to it — see `t:outcome/0`.

  A mid-turn machine gets `{:ignored, phase}` and **nothing is staged**, which is
  load-bearing rather than tidy: `pending_notice` is one slot shared with the
  iteration-budget reminder (a binary, written by `do_dispatch_http/1`) and read
  by `Machine.Compaction.resume/1`, so a map left there while the agent is busy
  would both disable the budget reminder (`||` treats a map as truthy) and be
  consumed by an unrelated later compaction, which would drop whatever that
  compaction carried. A map is therefore written only when the `:idle` machine
  can consume it in the same settle.
  """
  @spec apply_space_environment(Agent.t(), values()) :: {Agent.t(), outcome()}
  def apply_space_environment(state, values) do
    state = apply_mounts(state, values)

    if state.live.machine.phase == :idle do
      settle_notice(state, values)
    else
      {state, {:ignored, state.live.machine.phase}}
    end
  end

  # The mounts are what a tool call reads, so they move even for a machine that
  # cannot be told yet.
  defp apply_mounts(state, values) do
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

    %{state | tools: Tools.get_functions(names, Mounts.from_agent(state))}
  end

  # `:workspace_notice` is an `:idle` transition: it appends the pair when the
  # conversation fits, stages a compaction when it does not, and blocks when it
  # cannot be compacted. The slot is cleared on the way out of the first two, so
  # what is left in it tells the caller which one happened.
  defp settle_notice(state, values) do
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

    {:ok, settled} = Turn.settle(state, :workspace_notice)

    status = Machine.status_for(settled.live.machine)

    cond do
      # Any blocked phase means the pair was never appended and never will be:
      # the conversation cannot hold it (`:context_overflow`), or the compaction
      # that would have made room failed to start (`:compaction_loop_detected`
      # and friends). The caller keeps the flag, so the change survives to a
      # start.
      status in Machine.blocked_phases() ->
        {settled, {:error, status}}

      is_map(settled.live.machine.work.pending_notice) ->
        {settled, :deferred}

      true ->
        {settled, :appended}
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

  @doc """
  The values a *running* agent's mounts already carry.

  For the start path, where the change happened while the agent was stopped: the
  mounts were built from the space's current row, so the notice is a statement of
  what they say rather than of anything new.
  """
  @spec values_from_mounts(Agent.t()) :: values()
  def values_from_mounts(state) do
    %{
      workspace: Mounts.workspace(state.mounts),
      network_access: Mounts.network_access(state.mounts),
      backend: Mounts.backend(state.mounts)
    }
  end

  # One sentence per property, naming the values now in force. A single line
  # rather than a bulleted list because it is a notice, not a document.
  #
  # The mode sentence is here because the prompt's own enforcement sentence was
  # composed for the backend the agent *started* on and is never rebuilt (prefix
  # cache) — so after a backend change the prompt would keep making a claim the
  # new backend cannot honour. The notice is the only place that can correct it.
  defp body(values) do
    "This space's environment changed. Workspace: #{values.workspace || "(none)"}. " <>
      "Network access: #{if values.network_access, do: "enabled", else: "disabled"}. " <>
      "Sandbox: #{values.backend}. " <> enforcement_sentence(values.backend)
  end

  defp enforcement_sentence(backend) when backend in ["bwrap", "docker"] do
    "The `plan` restriction is enforced here: a write outside the scratch " <>
      "directory fails."
  end

  defp enforcement_sentence(_backend) do
    "The `plan` restriction is not enforced on this backend: nothing here stops " <>
      "a write, so keep to it yourself."
  end

  defp tool_names(state) do
    tools = if state.vocation, do: state.vocation.tools, else: []

    (tools || [])
    |> Groups.expand()
    |> ToolFilter.exclude_spawn_at_max_depth(state.depth)
  end
end

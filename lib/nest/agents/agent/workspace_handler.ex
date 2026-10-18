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
  deferred: the values ride that compaction's **entry**
  (`{:compaction, carried, values}`), and on success
  `Machine.Compaction.resume/1` appends the pair without an LLM request. They are
  on the entry rather than in `work.pending_notice` so that only the compaction
  that staged them can deliver them — a failed staging, a failed commit or any
  route out of the turn drops the entry and the notice with it.

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
    * `:deferred` — preflight decided the conversation needs compaction and a
      compaction is *in flight*: the values are on that compaction's entry
      (`{:compaction, carried, values}`), and `Machine.Compaction.resume/1`
      appends the pair when the commit lands. A failed staging, a failed commit
      or any route out of the turn drops the entry and the notice with it, so the
      caller must leave the flag set until the executor clears it at the append;
    * `{:ignored, phase}` — the machine is mid-turn, so the `:workspace_notice`
      transition has nowhere to land (it is `:idle`-only) and nothing is staged
      or appended. The caller must leave `space_notice_pending` set: the agent
      then announces the change when it next starts;
    * `{:error, status}` — the settle did not deliver the pair and nothing is in
      flight to deliver it later. `status` is where the machine ended up: a
      blocked phase (the conversation cannot hold the pair, or the compaction it
      would need could not start) or `:idle` (the compaction could not be staged
      at all, so the turn rested). The caller must leave the flag set.

  Only `:deferred` means "a compaction will append it"; everything else that is
  not `:appended` means the transcript does not have it, and the space's
  `space_notice_pending` flag must stay set.
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

  A mid-turn machine gets `{:ignored, phase}` and **nothing is staged**: the
  `:workspace_notice` transition is `:idle`-only, and the values' only other home
  is a compaction's entry, which only a settle that starts a compaction can
  write. `work.pending_notice` is never involved — it is the iteration-budget
  reminder's slot (`do_dispatch_http/1` writes it, `String.t() | nil`).
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
  # cannot be compacted. Three different things can be true afterwards, and none
  # of them is readable from the machine's status alone — so the transcript says
  # whether the pair landed, and the machine's *entry* says whether a compaction
  # has it.
  #
  # The values ride the event: a notice's lifetime is this settle, or the
  # compaction this settle stages (`Compaction.stage/3` puts it on that turn's
  # entry, where `Phase.enter/4` drops it with the turn). There is no slot for it
  # to outlive anything in.
  defp settle_notice(state, values) do
    {:ok, settled} = Turn.settle(state, {:workspace_notice, values})

    cond do
      # The transcript is the record of what happened to the *pair*, and the
      # status is not: the `:fits` arm appends it and then runs
      # `{:drain_inbox}`, and a drain can block *after* the pair is in. Asking
      # the status alone would report a failure for a notice the agent has, and
      # the caller would keep the flag and announce the same pair again at the
      # next start.
      appended_notice?(state, settled, values) ->
        {settled, :appended}

      # A compaction is carrying it and will append it on commit. Nothing else
      # can be holding the notice: `Compaction.stage/3` is the only writer, and
      # it only ever writes a compaction that started.
      staged_notice?(settled.live.machine) ->
        {settled, :deferred}

      true ->
        {settled, {:error, Machine.status_for(settled.live.machine)}}
    end
  end

  # The values a compaction staged for itself: on its entry, which is the only
  # place a notice can be in flight from.
  defp staged_notice?(%Machine{entry: {:compaction, _carried, notice}}), do: is_map(notice)
  defp staged_notice?(%Machine{}), do: false

  # Did *this* settle append the pair? Only the rows it added are considered, so
  # a pair from an earlier edit cannot be mistaken for this one.
  defp appended_notice?(before, settled, values) do
    text = notice_text(values)

    settled.chat_state.messages
    |> Enum.drop(length(before.chat_state.messages))
    |> Enum.any?(fn
      {:user, %{parts: parts}} -> Enum.any?(parts, &match?(%Part.Text{text: ^text}, &1))
      _other -> false
    end)
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
         parts: [%Part.Text{text: notice_text(values)}],
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

  # The pair's user row, in one place: `notice_pair/1` builds it and
  # `appended_notice?/3` looks for exactly this text in the rows a settle added.
  defp notice_text(values), do: "[mode: notice]\n" <> NoticeTag.tag(body(values))

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

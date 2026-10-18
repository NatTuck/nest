defmodule Nest.Agents.Agent.WorkspaceTest do
  @moduledoc """
  Tests for `WorkspaceHandler.apply_space_environment/2` — applying a change to
  the **space's** environment on a live agent — and for the workspace validation
  `Agents.create_agent/3` still performs.

  There is no per-agent workspace to edit: a workspace is
  `spaces.workspace_path`, so the agent edit dialog no longer carries one and
  `Agents.change_workspace/3` / `Agents.set_workspace/2` are gone. The caller is
  `Nest.Spaces.update_environment/2` (the space edit), so what these tests pin is
  the seam it uses: the mounts move, the tool closures are rebuilt against them,
  the persisted system prompt (index 0) is untouched to preserve the LLM prefix
  cache, and the change is announced as a user/assistant notice pair naming the
  values now in force — or, for a machine that cannot take it, left for the
  agent's next start.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup

  alias Ecto.Adapters.SQL.Sandbox

  alias Nest.Agents
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.Agents.AgentStateHelpers
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts
  alias Nest.Spaces
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    on_exit(fn -> :ok end)
    :ok
  end

  describe "apply_space_environment/2" do
    test "moves the mounts, rebuilds the tools, and appends the notice pair" do
      old = new_ws("old")
      new = new_ws("new")

      # A vocation with the file tools, so the rebuild has a closure to rebuild.
      {:ok, vocation} =
        Nest.Vocations.create_vocation(%{
          name: "WS Test (#{System.unique_integer([:positive])})",
          description: "writes to workspace",
          system_prompt: "workspace prompt",
          tools: ["file", "shell", "context"]
        })

      {pid, _name} =
        AgentTestHelpers.start_agent(%{workspace_path: old, vocation_id: vocation.id})

      # allowlist: snapshot — the mounts, tools and messages the apply moves
      before = :sys.get_state(pid, 1_000)
      assert Mounts.workspace(before.mounts) == old
      system_before = List.first(before.chat_state.messages)

      {state, :appended} =
        WorkspaceHandler.apply_space_environment(before, %{
          workspace: new,
          network_access: false,
          backend: "none"
        })

      # All three space properties ride the mounts, and all three moved.
      assert Mounts.workspace(state.mounts) == new
      assert Mounts.network_access(state.mounts) == false
      assert Mounts.backend(state.mounts) == "none"

      # Tool closures rebuilt against the new mounts.
      assert Enum.any?(state.tools, &(&1.name == "file-read"))

      # The system message (index 0) is untouched: rebuilding it would break the
      # prefix cache.
      assert List.first(state.chat_state.messages) == system_before

      # The notice pair is the new tail, and it states the values now in force
      # rather than a delta — a reconciliation, so two edits cannot leave the
      # agent holding a partial picture.
      assert [{:user, user}, {:assistant, assistant}] = Enum.take(state.chat_state.messages, -2)

      text = Enum.map_join(user.parts, "", &(&1.text || ""))

      assert text =~ "[nest notice]"
      assert text =~ "Workspace: #{new}"
      assert text =~ "Network access: disabled"
      assert text =~ "Sandbox: none"

      assert Enum.any?(assistant.parts, &(&1.text == "Space environment change confirmed."))
    end

    test "reapplies the max-depth spawn exclusion when tools are rebuilt" do
      {:ok, vocation} =
        Nest.Vocations.create_vocation(%{
          name: "WS Spawn (#{System.unique_integer([:positive])})",
          description: "spawn tools",
          system_prompt: "spawn prompt",
          tools: ["agents", "file"]
        })

      first = new_ws("spawn-old")
      second = new_ws("spawn-new")

      {pid, _name} =
        AgentTestHelpers.start_agent(%{workspace_path: first, vocation_id: vocation.id})

      # allowlist: snapshot — the tools the apply rebuilds
      before = :sys.get_state(pid, 1_000)
      assert Enum.any?(before.tools, &(&1.name == "agents-spawn"))

      # Below max depth the spawn tools survive the rebuild.
      {below, :appended} = apply_workspace(before, second)
      assert Enum.any?(below.tools, &(&1.name == "agents-spawn"))

      # At max depth they are dropped, matching `Init` and compaction.
      at_max = %{before | depth: Config.configured_max_depth()}
      {dropped, :appended} = apply_workspace(at_max, second)

      refute Enum.any?(dropped.tools, &(&1.name in ["agents-spawn", "agents-batch"]))
      assert Enum.any?(dropped.tools, &(&1.name == "file-read"))
    end
  end

  # The outcome decides whether the space's `space_notice_pending` flag is
  # cleared, and the flag is the only record that an agent still owes the
  # notice. A mid-turn machine cannot take it — `:workspace_notice` is an
  # `:idle` transition — so the apply reports that instead of staging a map the
  # machine would never consume (and that the budget reminder and the compactor
  # would both trip over).
  describe "apply_space_environment/2 outcomes" do
    test "an idle machine appends the pair, and the space's flag is cleared" do
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()
      workspace = new_ws("env-edit")

      # The whole caller, not a hand-rolled cast: the space edit writes the row,
      # marks the agent, and hands it the values.
      assert {:ok, _space} =
               Nest.Spaces.update_environment(space_id, %{workspace_path: workspace})

      # allowlist: barrier — the cast appends and clears the flag; no frame
      # announces either, so the read is the fence.
      state = :sys.get_state(pid, 1_000)

      assert Mounts.workspace(state.mounts) == workspace
      assert [notice] = notices(state)
      assert notice =~ "Workspace: #{workspace}"
      assert pending?(space_id, name) == false
    end

    test "a stopped agent is told at its next start, once" do
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()
      workspace = new_ws("env-stopped")

      # A stopped agent has no process to cast, so the edit can only mark it —
      # and the mark is what makes the announcement survive the stop.
      Process.unlink(pid)
      :ok = Supervisor.stop_agent(space_id, name)
      assert {:ok, _space} = Spaces.update_environment(space_id, %{workspace_path: workspace})
      assert pending?(space_id, name) == true

      {:ok, restarted} = Supervisor.get_agent(space_id, name)
      # The new pid's `init/1` self-sends the notice and appends it, which is a DB
      # write from a process this checkout does not otherwise reach.
      Sandbox.allow(Nest.Repo, self(), restarted)

      # allowlist: barrier — the start path appends and clears the flag, and
      # emits no frame of its own.
      state = :sys.get_state(restarted, 1_000)

      # One pair, not two: the start path is the only one that ran (there was no
      # process to cast), and the flag it clears is what keeps a later start from
      # announcing it again.
      assert [notice] = notices(state)
      assert notice =~ "Workspace: #{workspace}"
      assert pending?(space_id, name) == false
    end

    test "a mid-turn machine stages nothing, and the edit leaves it marked" do
      # Through the real edit, and *without* pre-setting the flag: the flag has to
      # come from the edit itself, or a busy agent is silently never told. That is
      # the whole subject — an agent the cast cannot reach is one whose only
      # record of the change is the row.
      for status <- [:streaming, :executing_tools] do
        {pid, name} = AgentTestHelpers.start_agent()
        space_id = AgentTestHelpers.current_space_id()

        # A turn in flight: the machine is not `:idle`, so the notice has
        # nowhere to land.
        _ = AgentStateHelpers.set_status(pid, status)
        workspace = new_ws("busy-#{status}")

        # `confirm: true`: a working agent makes the edit ask the user first
        # (`Nest.Spaces.update_environment/2`'s plan), and the user said yes. What
        # this test pins is what the *apply* does, not the prompt.
        assert {:ok, _space} =
                 Spaces.update_environment(space_id, %{workspace_path: workspace}, confirm: true)

        # allowlist: barrier — the cast is the only writer here.
        state = :sys.get_state(pid, 1_000)

        # The mounts moved — a command the agent runs next uses the space's
        # current values whatever the machine is doing.
        assert Mounts.workspace(state.mounts) == workspace

        # ...and nothing was appended or staged.
        assert notices(state) == []
        assert state.live.machine.work.pending_notice == nil

        # The flag is the record: it was set by the edit, the cast could not
        # deliver, and nothing cleared it — so the next start announces it.
        assert pending?(space_id, name) == true

        # Restore the fixture status, so the test's own leak check sees an idle
        # agent rather than one left mid-turn on purpose.
        _ = AgentStateHelpers.set_status(pid, :idle)
      end
    end

    test "a conversation with no headroom for a compaction keeps the flag, and stages nothing" do
      # The `:reserve_exhausted` rest: the transcript plus the reserve does not
      # fit, so preflight says `:needs_compaction`, and `Compaction.stage/2`
      # cannot fit the request into the reserve either — so it *rests*, leaving
      # the values in the slot. Nothing is in flight to append them, which makes
      # this the case that must not be reported as `:deferred`.
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()
      workspace = new_ws("env-no-headroom")

      AgentStateHelpers.replace_state(pid, fn state ->
        state = stuff_transcript(state)
        size = ConversationSize.size(state.chat_state.messages)

        put_in(state, [Access.key(:llm_metrics), Access.key(:context_limit)], size + 1)
      end)

      # The failed staging is a real failure and says so in the log; capture it
      # and assert on the line. The barrier is inside the capture because the
      # agent logs while it handles the cast.
      log =
        capture_log(fn ->
          assert {:ok, _space} =
                   Spaces.update_environment(space_id, %{workspace_path: workspace})

          # allowlist: barrier — the cast is the only writer here.
          state = :sys.get_state(pid, 1_000)
          send(self(), {:state, state})
        end)

      assert_received {:state, state}

      # Nothing was in flight, so nothing was deferred: the machine rested in
      # `:idle`, the slot was cleared, and the agent was not told what its
      # environment now is. (The staging failure appends its *own* notice —
      # "Compaction did not start…" — which is a different row and not the pair.)
      assert state.live.machine.phase == :idle
      assert state.live.machine.work.pending_notice == nil
      refute Enum.any?(notices(state), &(&1 =~ "This space's environment changed"))
      assert pending?(space_id, name) == true
      # The arm broadcasts its own `chat:error` ("Cannot compact: …"), which is
      # the expected log here.
      assert log =~ "Cannot compact"
    end

    test "a pair that lands before the settle leaves idle is still a delivery" do
      # `appended_notice?/3` exists because the machine's status after the settle
      # is not a statement about the *notice*: the `:fits` arm appends the pair and
      # then runs `{:drain_inbox}`, and the turn that drain starts can stage a
      # compaction — so the settle ends `:compacting`, with no notice on that
      # compaction's entry (it is the drain's, not the notice's). Deciding from
      # the status would report a failure for a notice the agent has, keep the
      # flag, and announce the same pair again at the next start.
      #
      # A limit one token above what the pair needs, plus one queued message: the
      # pair fits (and is appended), and the delivered message does not.
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()
      workspace = new_ws("env-then-compact")

      AgentStateHelpers.replace_state(pid, fn state ->
        pair_size =
          ConversationSize.size(
            state.chat_state.messages ++ WorkspaceHandler.notice_pair(notice_values(workspace))
          )

        %{
          state
          | llm_metrics: %{
              state.llm_metrics
              | context_limit: pair_size + Reserve.compaction_reserve(pair_size) + 1
            },
            live: %{state.live | inbox: [queued_entry("a message that does not fit")]}
        }
      end)

      assert {:ok, _space} = Spaces.update_environment(space_id, %{workspace_path: workspace})

      # allowlist: barrier — the cast is the only writer here.
      state = :sys.get_state(pid, 1_000)

      # The settle ended in a compaction turn, not idle...
      assert Machine.status_for(state.live.machine) == :compacting

      # ...and the notice is in the transcript, once, with the flag cleared.
      assert [_pair] = Enum.filter(notices(state), &(&1 =~ "This space's environment changed"))
      assert pending?(space_id, name) == false

      # Nothing staged the notice: that compaction is the drain's.
      assert {:compaction, _carried, nil} = state.live.machine.entry

      # Clean up the compaction this test started, so the leak check sees a
      # stopped agent rather than one mid-compaction.
      Process.unlink(pid)
      :ok = Supervisor.stop_agent(space_id, name)
    end

    test "a model-missing agent is told the change when its model is repaired" do
      # A `:model_missing` agent was blocked *at start*, so the start path's
      # notice never ran. The edit's cast is refused (the machine is blocked) and
      # the flag stays set; repairing the model is the one transition that
      # unblocks it, so that is where the notice has to be delivered — otherwise
      # the agent runs on mounts it has never been told about until it restarts.
      # Starting with an unknown model is the expected path here, and it logs;
      # capture it and assert on the line.
      log =
        capture_log(fn ->
          {pid, name} =
            AgentTestHelpers.start_agent(%{model: %{name: "ghost-model", provider: nil}})

          send(self(), {:agent, pid, name})
        end)

      assert_received {:agent, pid, name}
      assert log =~ "could not resolve model"

      space_id = AgentTestHelpers.current_space_id()
      # allowlist: snapshot — the status the fixture started in.
      assert Machine.status_for(:sys.get_state(pid, 1_000).live.machine) == :model_missing

      workspace = new_ws("env-model-missing")
      assert {:ok, _space} = Spaces.update_environment(space_id, %{workspace_path: workspace})
      assert pending?(space_id, name) == true

      :ok =
        Nest.Agents.change_model(space_id, name, %{
          name: "qwen3.5-plus",
          provider: "model-studio"
        })

      # allowlist: barrier — the unblock self-sends the notice; no frame
      # announces the append.
      state = :sys.get_state(pid, 1_000)

      assert Machine.status_for(state.live.machine) == :idle
      assert [notice] = Enum.filter(notices(state), &(&1 =~ "This space's environment changed"))
      assert notice =~ "Workspace: #{workspace}"
      assert pending?(space_id, name) == false
    end

    test "a conversation that cannot hold the pair reports the block, and keeps the flag" do
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()
      workspace = new_ws("env-too-small")

      # A limit too small for the system prompt alone: preflight's answer is
      # `:cannot_compact`, so the settle blocks in `:context_overflow` and the
      # pair is never appended. The flag has to survive that — a block is not a
      # delivery.
      AgentStateHelpers.replace_state(pid, fn state ->
        put_in(state, [Access.key(:llm_metrics), Access.key(:context_limit)], 1)
      end)

      # The block is a real failure and says so in the log, which is the expected
      # outcome here — so capture it and assert on the line rather than let it
      # print. The barrier is inside the capture: the agent logs while it handles
      # the cast, so the read is what guarantees the line is in the window.
      log =
        capture_log(fn ->
          assert {:ok, _space} =
                   Spaces.update_environment(space_id, %{workspace_path: workspace})

          # allowlist: barrier — the cast is the only writer here.
          state = :sys.get_state(pid, 1_000)
          send(self(), {:state, state})
        end)

      assert_received {:state, state}
      assert state.live.machine.phase == :context_overflow
      assert notices(state) == []
      assert pending?(space_id, name) == true
      assert log =~ "cannot fit the system prompt"
    end
  end

  describe "Agents.create_agent/3 workspace validation" do
    test "rejects a space whose workspace is missing or /tmp-rooted" do
      # The workspace is the space's, so this is where the value is validated on
      # the way into an agent — `spaces.workspace_path` is checked by
      # `Spaces.ensure_root_workspace/2` when the space is created, and an agent
      # start re-checks it because a space row can be backfilled with a path the
      # sandbox cannot bind.
      base = new_ws("create-base")
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, missing_space} =
        AgentTestHelpers.create_test_space(%{workspace_path: Path.join(base, "missing")})

      assert {:error, :workspace_missing} = Agents.create_agent(missing_space, model)

      {:ok, tmp_space} = AgentTestHelpers.create_test_space(%{workspace_path: "/tmp/ws"})
      assert {:error, :workspace_under_tmp} = Agents.create_agent(tmp_space, model)
    end
  end

  # The values an edit casts, as `apply_space_environment/2` wants them.
  defp notice_values(workspace) do
    %{workspace: workspace, network_access: true, backend: "bwrap"}
  end

  # One queued inbox entry, in the shape `Inbox.serialize/1` reads (the drain
  # builds its delivered message from it).
  defp queued_entry(content) do
    %{
      id: Inbox.new_id(),
      from: "peer",
      content: content,
      timestamp: DateTime.utc_now(),
      kind: :agent,
      mode: nil,
      human?: false,
      fulfilled_ids: []
    }
  end

  # A conversation big enough that the limit the caller derives from it leaves no
  # room for a compaction request: a `user` row with a large body, so the
  # transcript is the thing that is too big rather than the system prompt (which
  # would take the `:system_oversized` arm instead).
  defp stuff_transcript(state) do
    # A user/assistant exchange *before* the oversized row: `PreFlight` calls a
    # compaction with nothing but the system row ahead of the last user message a
    # no-op, which is a different arm (`:cannot_compact`).
    exchange = [
      {:user,
       %Nest.Messages.User{
         index: 1,
         parts: [%Nest.Messages.Part.Text{text: "hello"}],
         api_logs: []
       }},
      {:assistant,
       %Nest.Messages.Assistant{
         index: 2,
         parts: [%Nest.Messages.Part.Text{text: "hi"}],
         api_logs: []
       }}
    ]

    big =
      {:user,
       %Nest.Messages.User{
         index: 3,
         parts: [%Nest.Messages.Part.Text{text: String.duplicate("word ", 20_000)}],
         api_logs: []
       }}

    %{
      state
      | chat_state: %{state.chat_state | messages: state.chat_state.messages ++ exchange ++ [big]}
    }
  end

  defp pending?(space_id, name) do
    {:ok, row} = Persistence.fetch_agent(space_id, name)
    row.space_notice_pending
  end

  # The runtime notices in the transcript: the pair `WorkspaceHandler` appends.
  defp notices(state) do
    state.chat_state.messages
    |> Enum.map(fn {_role, message} -> text_of(message) end)
    |> Enum.filter(&(&1 =~ "[nest notice]"))
  end

  defp text_of(%{parts: parts}) do
    Enum.map_join(parts, "", fn
      %{text: text} when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp apply_workspace(state, path) do
    WorkspaceHandler.apply_space_environment(state, %{
      workspace: path,
      network_access: Mounts.network_access(state.mounts),
      backend: Mounts.backend(state.mounts)
    })
  end

  # A real workspace directory outside /tmp: the scratch dir is bound at /tmp,
  # so a /tmp-rooted workspace is rejected, and a non-existent one too.
  defp new_ws(label) do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_ws_#{label}_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_ws_") end)
    dir
  end
end

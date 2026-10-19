defmodule Nest.Agents.Agent.SpaceNoticeCommitTest do
  @moduledoc """
  The **deferred** half of the space-environment notice, end to end: what happens
  between a compaction that was staged to deliver the notice and the commit that
  appends it.

  The values ride the compaction's entry (`{:compaction, carried, values}`), so
  the pair is appended by `Machine.Compaction.resume/1` on the commit — and the
  space's `space_notice_pending` flag is cleared by an executor action *after*
  that append, only while the row still holds the values the notice names. Both
  halves are pinned here: the flag must stay set while the notice is only staged
  (a stop, archive, crash or deploy before the commit loses the entry, and the
  next start is what announces it), and a second edit that lands while the
  compaction is in flight must not have its mark erased by the first one's
  commit.

  Split out of `Nest.Agents.AgentCompactionTest`, which is at the credo
  file-length cap.
  """

  use Nest.DataCase, async: true

  import Mimic

  import Nest.Agents.AgentTestHelpers

  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.User
  alias Nest.Persistence

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  defp pending?(space_id, name) do
    {:ok, row} = Persistence.fetch_agent(space_id, name)
    row.space_notice_pending
  end

  # The deferred half of the space-notice path, end to end: the values ride the
  # compaction's entry, the space's `space_notice_pending` flag stays set for as
  # long as they are only staged, and the commit both appends the pair and clears
  # the flag (the executor's `{:clear_space_notice, values}`).
  describe "a deferred space-environment notice" do
    test "is appended by the commit, and the space's flag lands with it" do
      {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      space_id = current_space_id()

      # The values the space's row actually holds, in the entry's spelling: the
      # clear compares them against the row, so a staged notice that is still
      # current is the case this test is about.
      environment = Nest.Spaces.environment(space_id)

      values = %{
        kind: :workspace,
        workspace: environment.workspace_path,
        network_access: environment.network_access,
        backend: environment.sandbox_backend
      }

      # What a space edit leaves behind when the notice is deferred.
      :ok = Persistence.set_space_notice_pending(space_id, name, true)

      ref = make_ref()

      :sys.replace_state(
        pid,
        fn s ->
          machine = s.live.machine

          machine = %{
            machine
            | kind: :compaction,
              phase: :generating,
              entry: {:compaction, nil, values},
              work: %{
                machine.work
                | worker_kind: :http,
                  worker_ref: ref,
                  active_message_index: s.chat_state.next_message_index
              }
          }

          %{s | live: %{s.live | machine: machine}}
        end,
        1_000
      )

      # In flight: staged, and the flag is still set — the row must not claim the
      # agent was told while the values are only in machine state.
      assert pending?(space_id, name) == true

      send(pid, {:http_response, ref, %RunResponse{text: "a summary", usage: nil}})

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # allowlist: barrier — the notice append is one of the commit's actions and
      # broadcasts no frame of its own; the idle frame above precedes the append,
      # so the read is what orders the assertions.
      state = :sys.get_state(pid, 1_000)

      assert [_notice] =
               for(
                 {:user, %User{parts: parts}} <- state.chat_state.messages,
                 text = Enum.map_join(parts, "", & &1.text),
                 text =~ "This space's environment changed",
                 do: text
               )

      # ...and the flag is cleared only now, by the action the append ordered.
      assert pending?(space_id, name) == false

      # It is in the transcript the UI reads, not only in memory.
      persisted = Persistence.load_messages(space_id, name)

      assert Enum.any?(persisted, fn
               {:user, %User{parts: parts}} ->
                 Enum.any?(parts, &(&1.text =~ "This space's environment changed"))

               _other ->
                 false
             end)
    end
  end

  # The executor's guard, which is the residual this round decided: a second edit
  # that lands while the compaction is in flight has marked the row again and
  # moved the agent's mounts, so this commit's clear must not erase that mark.
  test "does not clear the flag when the space has moved on since the deferral" do
    {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}})
    space_id = current_space_id()

    # Values the row does *not* hold: the space was edited after this notice was
    # staged.
    stale = %{
      kind: :workspace,
      workspace: "/home/nat/elsewhere",
      network_access: true,
      backend: "bwrap"
    }

    :ok = Persistence.set_space_notice_pending(space_id, name, true)
    ref = make_ref()

    :sys.replace_state(
      pid,
      fn s ->
        machine = s.live.machine

        machine = %{
          machine
          | kind: :compaction,
            phase: :generating,
            entry: {:compaction, nil, stale},
            work: %{
              machine.work
              | worker_kind: :http,
                worker_ref: ref,
                active_message_index: s.chat_state.next_message_index
            }
        }

        %{s | live: %{s.live | machine: machine}}
      end,
      1_000
    )

    send(pid, {:http_response, ref, %RunResponse{text: "a summary", usage: nil}})

    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    # The pair is appended — it names what was staged — but the mark survives, so
    # the next start announces the environment that is actually in force.
    assert pending?(space_id, name) == true
  end
end

defmodule Nest.Agents.Agent.Turn.DrainFailureTest do
  @moduledoc """
  The drain's failure path: a batch that cannot be admitted is surfaced, not
  inlined and not dropped.

  Split out of `Turn.ExecutorTest`, which is at its file-length cap (issue #80)
  — the same remedy `test/support/executor_test_helpers.ex` records. The fixture
  is the one those tests use (`Nest.TestSupport.ExecutorTestHelpers`), so the
  state here is a real session with a real row.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup
  import Nest.TestSupport.ExecutorTestHelpers

  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Turn.Executor
  alias Nest.Sandbox.Mounts
  alias Nest.TextFixtures

  test "a batch that cannot be admitted is a visible error and stays queued" do
    # intentional: over the inline cap *and* unfilable, so there is nothing to
    # deliver. `Drain.failed/2` answers with a visible error and an untouched
    # queue — inlining over the budget or dropping the batch would each lose the
    # message with no trace.
    dir = Path.join(System.tmp_dir!(), "exec-drain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    # Unwritable, so the scratch write fails deterministically: no timing, no
    # second attempt.
    File.chmod!(dir, 0o500)

    on_exit(fn ->
      File.chmod(dir, 0o700)
      rm_tmp!(dir, "exec-drain-")
    end)

    peer = entry(:agent, "peer", TextFixtures.big_text(40_000))
    state = %{inbox_state([peer], "act") | mounts: Mounts.new(nil, dir)}
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

    log =
      capture_log(fn ->
        # No follow event: there is nothing to deliver, so the drain is over.
        {next, nil} = Executor.run_all([{:drain_inbox}], state)

        # Nothing was consumed: the entry is still the queue, and no `chat:inbox`
        # frame said otherwise.
        assert next.live.inbox == [peer]
        refute_received {:chat_inbox, _}
      end)

    # The frame the channel forwards to the browser as `chat:error`, and the line
    # the server logs: both name the reason.
    assert_receive {:chat_error, %{content: content}}, 1_000
    assert content =~ "could not be written"
    assert log =~ "could not be written"
  end

  # The documented entry shape (`Inbox.t:entry/0`): the removal delta names an
  # entry by its `id`, so a fixture without one is not an entry a queue holds.
  defp entry(kind, from, content) do
    %{
      id: Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: nil,
      source: false,
      fulfilled_ids: []
    }
  end

  defp inbox_state(entries, mode) do
    base = state()
    %{base | live: %{base.live | inbox: entries, mode: mode}}
  end
end

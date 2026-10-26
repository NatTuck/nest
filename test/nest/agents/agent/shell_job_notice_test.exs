defmodule Nest.Agents.Agent.ShellJobNoticeTest do
  @moduledoc """
  The background job exit notice (issue #163).

  `Nest.Sandbox.ShellJobs.finish_job/3` is a job's single exit point, and it
  used to tell only the job's *waiters* (the watcher behind `shell-wait`) and
  the UI. An agent that started a job and did anything else was never told it
  ended. The manager now casts the notice to the owning agent, which enqueues it
  as a `:runtime` entry and drains it when it is idle.

  The wording half is here because the notice must say exactly what `shell-wait`
  says (`ShellJobs.result_text/3`) — one exit, one sentence — with the job's log
  as its own `:output` segment (issue #139). The delivery half is the manager's,
  and is pinned where its fixtures live:
  `test/nest/sandbox/shell_jobs_test.exs`.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ShellJobNotice
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.Paths
  alias Nest.Sandbox.ShellJobs

  setup :verify_on_exit!

  describe "parts/3 and notice/3" do
    test "the log is its own output segment and a job with no output has none" do
      assert ShellJobNotice.parts("job-3", 0, "done\n") == [
               {:text, "Background job job-3 exited with code 0:\n"},
               {:output, "done\n"}
             ]

      # Nothing to render as output: one prose segment, exactly `result_text/3`.
      assert ShellJobNotice.parts("job-3", 0, "") ==
               [{:text, "Background job job-3 exited 0 with no output."}]

      # A nonzero exit with no log keeps `result_text/3`'s wording, trailing
      # newline and all.
      assert ShellJobNotice.parts("job-3", 2, "") ==
               [{:text, "Background job job-3 exited with code 2:\n"}]
    end

    test "a multibyte log is split off by bytes, not graphemes" do
      # `String.split_at/2` counts graphemes, so a byte offset happens to work
      # only while the prose is ASCII — a multibyte character anywhere in
      # `result_text/3`'s prose would have shifted the split silently, and two
      # characters of the log would have been rendered as prose. The log itself
      # is the case this module exists to carry, so it is the one pinned here.
      output = "héllo ☃ wörld\n"

      assert [{:text, prose}, {:output, ^output}] =
               ShellJobNotice.parts("job-3", 3, output)

      assert prose == "Background job job-3 exited with code 3:\n"
    end

    test "notice/3 is exactly the join of parts/3, which is shell-wait's answer" do
      for {code, output} <- [{0, ""}, {0, "done\n"}, {137, "killed\n"}] do
        parts = ShellJobNotice.parts("job-3", code, output)

        assert ShellJobNotice.notice("job-3", code, output) ==
                 Enum.map_join(parts, "", &elem(&1, 1))

        assert ShellJobNotice.notice("job-3", code, output) ==
                 ShellJobs.result_text("job-3", code, output)
      end
    end
  end

  describe "the owning agent" do
    setup do
      {pid, name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
      %{pid: pid, name: name, space_id: AgentTestHelpers.current_space_id()}
    end

    test "an idle agent takes a turn on its job's exit notice", %{
      pid: pid,
      name: name,
      space_id: space_id
    } do
      key = {space_id, name}
      MockClient.set_response("acknowledged")
      id = start_job!(pid, key, "echo done\n")

      # The notice drains into a turn; that turn's own user-message broadcast is
      # the event that says it landed. Nothing subscribed to the job, so the
      # manager's cast is the only thing that could have started this turn.
      assert_receive {:chat_message, {:user, _}}, 1_000

      # Exactly one row about the job: a notice *and* something else (the job
      # reported twice) is the failure this pins.
      {:user, notice} = notice_message(pid, id)
      texts = Enum.map(notice.parts, & &1.text)

      # The runtime's own words — no agent said this — and `shell-wait`'s
      # sentence, so the two ways of learning an exit agree: everything after
      # the header is `result_text/3` byte for byte.
      assert [prose, log] = texts
      assert [header, body] = String.split(prose, "\n", parts: 2)
      assert header =~ "[From nest runtime"
      assert body <> log == ShellJobs.result_text(id, 0, "done\n")
      assert log == "done\n"

      # The log is marked as command output (issue #139), so the client renders
      # it verbatim instead of as markdown.
      assert notice.metadata["command_output_parts"] == [1]

      await_idle(pid)
    end
  end

  # A background job started the way `shell-cmd` starts one — the agent's own
  # mounts, a staged script, the agent's pid as owner — but without the tool's
  # own subscribe (`ShellCmd` registers its caller as a waiter for the grace
  # window), so the exit is reached with no waiter: the case this notice exists
  # for, and the only way to reach it without racing that subscribe.
  defp start_job!(pid, key, body) do
    # allowlist: snapshot — the agent's own mounts, which is what its tools hand
    # to a background job.
    state = :sys.get_state(pid, 1_000)
    mounts = Mounts.from_agent(state)

    {:ok, id, _log_path} =
      ShellJobs.start_job(%{
        agent_key: key,
        agent_pid: pid,
        command: String.trim(body),
        script_sandbox: stage_script!(Mounts.scratch(mounts), body),
        script_path: nil,
        mounts: mounts,
        max_jobs: 1,
        # No waiter: this stands in for a job whose tool call walked away, which
        # is the case the notice exists for. `start_job/1` would otherwise
        # register this test process, and the notice would be suppressed.
        waiter: nil
      })

    id
  end

  # `Nest.Tools.ShellCmd.Transcript.stage/2`'s layout: the script's host path and its
  # in-sandbox spelling, which is what the backend's command line runs.
  defp stage_script!(scratch, body) do
    dir = Paths.stage_dir(scratch)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "run.sh"), body)
    Path.join(Paths.stage_dir_sandbox(scratch), "run.sh")
  end

  # The one user row that mentions `id`.
  defp notice_message(pid, id) do
    assert [message] =
             pid
             |> Agent.get_messages(1_000)
             |> Enum.filter(fn
               {:user, %{parts: parts}} -> Enum.any?(parts, &String.contains?(&1.text, id))
               _other -> false
             end)

    message
  end

  # The notice's turn has ended: its own status frame is the event, and the
  # read after it is a read of the settled state rather than a wait. A bare
  # `idle` is not the fence — a turn end that drains publishes the transient
  # `streaming -> idle -> streaming` of issue #15 first, so the fence is the
  # idle that carries an empty queue.
  defp await_idle(pid) do
    assert_receive {:chat_status, %{status: "idle", pendingMessageCount: 0}}, 1_000
    assert Agent.get_public_info(pid, 1_000).status == :idle
  end
end

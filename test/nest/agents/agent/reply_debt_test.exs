defmodule Nest.Agents.Agent.ReplyDebtTest do
  @moduledoc """
  The reply obligation (issue #31 §1.2–§1.6) end to end, against a real agent:
  where the debt is set, that a compaction leaves it alone, that a successful
  reply clears it before the turn settles, that a failed send does not, and that
  the runtime gives up on it — with an honest notice to the requester — instead
  of idling while it is still owed.

  The pure decision table and the give-up audit live in `MachineDebtTest`; this
  file is the runtime contract around them.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part

  setup :verify_on_exit!

  # The per-test `MockClient` queue, so a test can script responses *before*
  # `start_agent/1` hands the queue to the agent (the `TurnAcceptanceTest`
  # fixture).
  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers

  describe "the debt's lifetime" do
    test "a compaction's commit keeps the debt, and the turn that follows gives it up" do
      # intentional: the commit rewrites the conversation (a new active segment,
      # a reset projection) and never the machine, so the obligation outlives the
      # segment it was incurred in — the give-up below only fires because the
      # machine still held the debt after the commit. The resume's carried-reply
      # arm then asks the gate (the reply is committed, so the turn is not over):
      # it reminds once, and the settle after that reminder gives the reply up
      # rather than leaving it owed.
      {pid, _name} = start_agent(default_attrs())
      peer = start_peer("peer", "peer handled the notice")

      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["peer"])}
        }
      end)

      state = :sys.get_state(pid)
      assert Machine.owed_senders(state.live.machine) == ["peer"]

      # Invisible to the model: the turn context (what the request is built
      # from) has no debt field, and setting the debt wrote no message.
      refute Map.has_key?(Turn.build_ctx(state), :owed_replies)
      refute Enum.any?(texts(state), &(&1 =~ "owe"))

      AgentTestHelpers.send_compaction_done(pid, "a summary", carried_reply())

      assert Eventually.eventually(
               fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
               timeout: 500
             )

      state = :sys.get_state(pid)

      # The commit really ran (the summary landed) and the debt is gone.
      assert Enum.any?(texts(state), &(&1 =~ "a summary"))
      assert Machine.owed_senders(state.live.machine) == []

      # The requester was told, and a notice creates no obligation of its own.
      assert Eventually.eventually(
               fn -> Enum.any?(peer_texts(peer), &(&1 =~ "did not reply")) end,
               timeout: 500
             )

      assert Machine.owed_senders(:sys.get_state(peer).live.machine) == []
      wait_idle(peer)
    end

    test "a reply that reaches the peer clears it before the turn settles" do
      # intentional: the tool worker casts the clear from its own process
      # *before* its `{:tool_results, …}`, so the machine has already discharged
      # the debt when the final response settles — the idle gate must never
      # remind for a reply that is in flight. The peer is a real agent, so the
      # reply genuinely lands in its transcript.
      MockClient.set_tool_response(%{
        text: "replying",
        tool_calls: [
          %{
            id: "s1",
            name: "agents-send",
            arguments: %{"name" => "peer", "message" => "here is the answer"}
          }
        ]
      })

      MockClient.set_response("done")

      {pid, name} = start_agent(default_attrs())
      peer = start_peer("peer", "peer ack")

      assert {:ok, :delivered} =
               Agents.send_message(current_space_id(), "peer", name, "please summarize", :query)

      assert Machine.owed_senders(:sys.get_state(pid).live.machine) == ["peer"]

      # The tool batch is its own status, and the settle is the first idle: no
      # reminder and no give-up came in between.
      assert statuses_until_idle() == ["streaming", "executing_tools", "streaming", "idle"]

      state = :sys.get_state(pid)

      refute Enum.any?(agent_user_texts(state), &(&1 =~ "have not answered"))
      assert Machine.owed_senders(state.live.machine) == []

      assert Eventually.eventually(
               fn -> Enum.any?(peer_texts(peer), &(&1 =~ "here is the answer")) end,
               timeout: 500
             )

      # No give-up notice: the reply was the answer, not a surrender.
      refute Enum.any?(peer_texts(peer), &(&1 =~ "did not reply"))
    end

    test "a failed send leaves the debt standing, so the gate still reminds" do
      # intentional: only a *successful* delivery clears the obligation
      # (decision 11). The send here targets an agent that does not exist, so
      # nothing was delivered and the debt survives to the gate.
      MockClient.set_tool_response(%{
        text: "replying",
        tool_calls: [
          %{
            id: "s1",
            name: "agents-send",
            arguments: %{"name" => "ghost", "message" => "hello?"}
          }
        ]
      })

      MockClient.set_response("done")
      MockClient.set_response("still here")

      {pid, name} = start_agent(default_attrs())
      peer = start_peer("peer", "peer handled the notice")

      # The refused send is an `is_error` tool result, which BatchSizer logs:
      # expected, so capture it (and assert it) instead of printing it.
      log =
        capture_log(fn ->
          assert {:ok, :delivered} =
                   Agents.send_message(
                     current_space_id(),
                     "peer",
                     name,
                     "please summarize",
                     :query
                   )

          assert statuses_until_idle() == ["streaming", "executing_tools", "streaming", "idle"]
        end)

      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "ghost"

      state = :sys.get_state(pid)

      # The gate reminded once, naming the still-unanswered peer, and the
      # budget's end gave the reply up (which the peer is told about).
      reminded =
        Enum.filter(agent_user_texts(state), &(&1 =~ "have not answered" and &1 =~ "peer"))

      assert length(reminded) == 1
      assert Machine.owed_senders(state.live.machine) == []

      assert Eventually.eventually(
               fn -> Enum.any?(peer_texts(peer), &(&1 =~ "did not reply")) end,
               timeout: 500
             )

      wait_idle(peer)
    end
  end

  describe "the idle gate" do
    test "reminds once, names the debtor, then gives up with a notice" do
      # intentional: the query is delivered to an idle agent, so the debt is set
      # before the model runs. Neither scripted reply answers the peer, so the
      # first settle would be an idle: the gate injects the reminder and keeps
      # the turn in `:generating` (no transient idle — #15), and the second
      # settle, its budget spent, gives up — the requester is told, rather than
      # being left waiting on an agent that reports `:idle`.
      MockClient.set_response("I will look into it")
      MockClient.set_response("Still thinking about it")

      {pid, name} = start_agent(default_attrs())
      peer = start_peer("peer", "peer handled the notice")
      spy_on_requests(pid)

      assert {:ok, :delivered} =
               Agents.send_message(current_space_id(), "peer", name, "please summarize", :query)

      # The debt is set at delivery and rides the status broadcast (decision 15).
      assert Machine.owed_senders(:sys.get_state(pid).live.machine) == ["peer"]
      assert_receive {:chat_status, %{status: "streaming", owedReplies: ["peer"]}}, 500

      # The model's first request carries the query and nothing about the debt:
      # the obligation is invisible until the gate reminds.
      first = assert_request()
      assert Enum.any?(user_texts(first), &(&1 =~ "please summarize"))
      refute Enum.any?(user_texts(first), &(&1 =~ "have not answered"))

      # The reminder is a second request whose context now carries the notice
      # naming the debtor.
      second = assert_request()
      assert Enum.any?(user_texts(second), &(&1 =~ "have not answered" and &1 =~ "peer"))

      # The reminder itself caused no status frame (the phase never left
      # `:generating`), so the next frame is the give-up's idle.
      assert statuses_until_idle() == ["idle"]

      state = :sys.get_state(pid)

      assert length(Enum.filter(agent_user_texts(state), &(&1 =~ "have not answered"))) == 1
      assert Machine.owed_senders(state.live.machine) == []

      # Exactly two requests: one reminder, never a second.
      refute_receive {:llm_request, _}, 50

      # The requester learned that no answer is coming, as the runtime's own
      # words: the notice arrives bare, with no `[Message from agent …]` label.
      assert Eventually.eventually(
               fn ->
                 Enum.any?(
                   peer_texts(peer),
                   &(&1 =~ "did not reply" and not String.contains?(&1, "Message from agent"))
                 )
               end,
               timeout: 500
             )

      assert Machine.owed_senders(:sys.get_state(peer).live.machine) == []
      wait_idle(peer)
    end
  end

  describe "a refused give-up" do
    test "is logged and notified, never swallowed" do
      # intentional: the runtime is dropping an obligation, so a requester it
      # cannot reach must still leave a trace — the server log and a
      # `chat:notification` on the giving-up agent's own topic, mirroring
      # any other delivery refusal. The notification is asserted inside the
      # capture because it is broadcast *after* the warning, which is what
      # proves the warning landed.
      {pid, _name} = start_agent(default_attrs())
      peer = start_peer("peer", "peer ack")
      set_status(peer, :needs_repair)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["peer"])}
        }
      end)

      log =
        capture_log(fn ->
          AgentTestHelpers.send_compaction_done(pid, "a summary", carried_reply())
          assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 500
        end)

      # The carried reply reminds first (the gate), so the give-up that gets
      # refused here is the one the *next* would-be-rest emits once the budget
      # is spent — the refusal is the same either way.
      assert log =~ "reply give-up (no_reminder) could not reach peer"
      assert log =~ "needs_repair"

      # The debt is discharged regardless: the runtime gave up on it.
      assert Machine.owed_senders(:sys.get_state(pid).live.machine) == []
    end
  end

  describe "an agent that goes away with the debt still owed" do
    test "an archive gives the reply up before the process goes away" do
      # intentional: an archive (or a stop — both go through the supervisor's
      # `stop_one/2`) *ends* the agent, so the peers it still owes hear that no
      # answer is coming before the process is gone (decision 12). This is the
      # one place the give-up cannot be the machine's: there is no settle left to
      # emit the action from, and `Agent.terminate/2` is the wrong home for it (a
      # shutdown there must not read the DB or start processes).
      #
      # Trapping exits: the agent is linked to this process and the archive stops
      # it, so an untrapped `:shutdown` would take the test (and the sandbox
      # ownership the peer's turn needs) with it.
      Process.flag(:trap_exit, true)
      {pid, name} = start_agent(default_attrs())
      peer = start_peer("peer", "peer handled the notice")

      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["peer"])}
        }
      end)

      # The debt was discharged on the way out, so the peer is told before the
      # process goes away. That notice is the observable this pins, and the
      # sibling test below pins the other half (a death outside the stop path
      # has nothing to tell the peer, and logs the lost obligation).
      #
      # The *absence* of that warning here is deliberately not asserted:
      # `capture_log` collects every process's logs — including concurrent
      # tests' agents, which log the same sentence for their own peers — so an
      # absence assertion there flakes and tests nothing.
      assert :ok = Supervisor.archive_agent(current_space_id(), name)

      # The process is gone, so its `terminate/2` has run: the registry entry
      # goes with the process.
      assert Eventually.eventually(
               fn ->
                 Supervisor.get_running_agent(current_space_id(), name) ==
                   {:error, :not_found}
               end,
               timeout: 500
             )

      assert Eventually.eventually(
               fn -> Enum.any?(peer_texts(peer), &(&1 =~ "did not reply")) end,
               timeout: 500
             )

      wait_idle(peer)
    end

    test "a process that dies outside the stop path records the lost obligation" do
      # intentional: the debt is in-process state, so a death that does not go
      # through the supervisor's stop path — a reload, a crash, a supervisor
      # shutdown — drops it without the requester hearing anything. That is the
      # accepted disposition (decision 12's restart half, which the runtime
      # accepts because the agent comes back with a fresh machine), but the
      # server log has to say it happened.
      {pid, _name} = start_agent(default_attrs())

      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["peer"])}
        }
      end)

      log = capture_log(fn -> GenServer.stop(pid) end)

      assert log =~ "stopping with unpaid replies to [\"peer\"]"
      assert log =~ "the obligation is in-process state and is lost"
    end
  end

  # --- helpers ---

  defp default_attrs do
    %{model: %{name: "qwen3.5-plus"}, vocation_id: programmer_vocation_id_for_test()}
  end

  # A reply the compactor carried across the boundary: the resume commits it and
  # finalises, which is the terminal site the give-up has to catch.
  defp carried_reply do
    reply =
      Turn.Messages.assistant(%RunResponse{
        text: "carried",
        thinking: nil,
        tool_calls: [],
        refusal: nil,
        stop_reason: :end_turn,
        model: "m",
        usage: %{}
      })

    {:assistant_response, reply, 0, 10}
  end

  # A real second agent in the current space, mocked so its own turn never
  # touches the network. `start_agent/1` always makes a fresh space, so a peer
  # needs the manual path (the same one `SubAgentToolsTest` uses).
  defp start_peer(name, response) do
    space_id = current_space_id()

    {:ok, ^name} =
      Agents.create_agent(space_id, %{name: "qwen3.5-plus", provider: "model-studio"},
        name: name,
        vocation_id: vocation_id_for_test()
      )

    {:ok, pid} = Supervisor.get_agent(space_id, name)
    Sandbox.allow(Nest.Repo, self(), pid)

    :sys.replace_state(pid, fn st ->
      %{st | client_config: %{st.client_config | client: MockClient}}
    end)

    MockClient.start_link(pid)
    MockClient.put_pending(pid, {:text, response})
    AgentTestHelpers.ensure_cleanup(name)

    pid
  end

  # A peer that received a notice runs a turn on it; the teardown rejects an
  # agent left in flight, so wait for it to settle.
  defp wait_idle(pid) do
    assert Eventually.eventually(
             fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
             timeout: 500
           )
  end

  # Put an agent into an arbitrary machine status, as `InboxTest` does. Only the
  # blocked statuses are used here: the teardown's zero-remaining check rejects
  # an agent left *in flight*.
  defp set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, status)}
      }
    end)
  end

  # Record the message list of every request the agent's turn makes, then hand
  # off to the scripted `MockClient` (the `TurnAcceptanceTest` spy).
  defp spy_on_requests(pid) do
    test_pid = self()

    Mimic.stub(MockClient, :run, fn request, opts ->
      send(test_pid, {:llm_request, request.messages})
      Mimic.call_original(MockClient, :run, [request, opts])
    end)

    Mimic.allow(MockClient, self(), pid)
  end

  # The `{:user, _}` texts of an *agent state* (the `AgentTurnTestHelpers`
  # `user_texts/1` takes a message list).
  defp agent_user_texts(state), do: user_texts(state.chat_state.messages)

  defp texts(state) do
    state.chat_state.messages
    |> Enum.flat_map(fn
      {_tag, %{parts: parts}} -> [parts_text(parts)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp peer_texts(pid), do: texts(:sys.get_state(pid))

  defp parts_text(parts) do
    Enum.map_join(parts || [], "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end
end

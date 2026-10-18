defmodule Nest.Agents.Agent.MessageAppendTagsTest do
  @moduledoc """
  Step 6 of `notes/continue.md`: no-crash appends + the single repair
  decision.

  `MessageAppender` returns `{:ok, stamped, state} | {:stale, state} |
  {:invalid, reason, state}` and never raises on a sequence mismatch.
  `Nest.Agents.Agent.Repair.decide/3` is the one decision table; the
  live context classifies (no repair, except the user-onto-user-tail
  bridge), the terminal/worker-death/load contexts heal. These tests pin
  the `Repair` decision table and the caller behavior for `:stale` (drop
  with a notice) and `:invalid` (fail the turn to idle with
  `chat:error`).
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Callbacks
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.Agent.Turn
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  describe "Repair.decide/3" do
    test ":live classifies ok, stale, and invalid, bridging only user-after-user" do
      assert :ok = Repair.decide(:live, [user(0)], assistant_text(1))

      assert :stale = Repair.decide(:live, [assistant_tool_use(0, "a")], tool_result(1, "b"))

      assert {:invalid, reason} =
               Repair.decide(:live, [assistant_tool_use(0, "a")], user(1))

      assert reason =~ "live tool_use"

      assert {:invalid, reason} =
               Repair.decide(:live, [user(0), assistant_text(1)], assistant_text(2))

      assert reason =~ "second consecutive assistant"

      # The one live-path repair: a user message onto a wire-user tail is
      # bridged (this can only be the turn-opening append).
      assert {:repair, [{:assistant, %Assistant{parts: [%Part.Text{text: text}]}}]} =
               Repair.decide(:live, [user(0)], user(1))

      assert text =~ "continuing from here"

      # A `{:tool, _}` tail is wire-user too: same single ack.
      assert {:repair, [{:assistant, %Assistant{}}]} =
               Repair.decide(:live, [assistant_tool_use(0, "a"), tool_result(1, "a")], user(2))
    end

    test ":worker_death answers an unpaired tail, or :none when clean" do
      assert {:repair,
              [
                {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "a", is_error: true}]}}
              ]} = Repair.decide(:worker_death, [user(0), assistant_tool_use(1, "a")], nil)

      assert :none = Repair.decide(:worker_death, [user(0), assistant_text(1)], nil)
    end

    test ":terminal heals with the pairing bridge" do
      assert {:repair, []} = Repair.decide(:terminal, [user(0), assistant_text(1)], user(2))

      assert {:repair, [{:tool, _}, {:assistant, _}]} =
               Repair.decide(:terminal, [user(0), assistant_tool_use(1, "a")], user(2))
    end

    test ":load classifies clean, bridged, interrupted, and real violations" do
      assert :ok = Repair.decide(:load, [system(0), user(1), assistant_text(2)], nil)

      assert {:bridge, [{:assistant, %Assistant{parts: [%Part.Text{text: text}]}}]} =
               Repair.decide(:load, [system(0), user(1)], nil)

      assert text =~ "interrupted"

      assert {:interrupted, [%Part.ToolUse{id: "a"}]} =
               Repair.decide(:load, [system(0), user(1), assistant_tool_use(2, "a")], nil)

      assert {:violations, [_ | _]} =
               Repair.decide(:load, [user(0), assistant_text(1), assistant_text(2)], nil)
    end

    test ":live treats a malformed result as stale and a wire-ignored role as invalid" do
      # A `{:tool, _}` with nil parts cannot answer the pending tool_use.
      assert :stale =
               Repair.decide(:live, [assistant_tool_use(0, "a")], {:tool, %Tool{parts: nil}})

      # A wire-ignored role while a tool_use is pending is still broken.
      assert {:invalid, reason} =
               Repair.decide(:live, [assistant_tool_use(0, "a")], system(1))

      assert reason =~ "nil"
    end

    test "load_heal/1 is empty when there is nothing to answer" do
      assert [] = Repair.load_heal([])
    end

    test ":offline defers to the offline authority" do
      assert :offline_authority = Repair.decide(:offline, [], nil)
    end

    test "the declared contexts cover every decision path" do
      assert Repair.contexts() == [:live, :worker_death, :terminal, :load, :offline]
    end
  end

  describe "MessageAppender live-path tags" do
    test "an invalid live append fails the turn to idle with chat:error" do
      name = unique_name("live-invalid-turn")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_text(2)]
      insert_messages(name, initial)

      state = state(name, initial) |> live(:streaming)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{name}")

      assert {:invalid, reason, state} =
               MessageAppender.append_one(state, assistant_text(nil))

      {final, log} =
        with_log(fn ->
          {:ok, final} = Turn.settle(state, {:append_result, :invalid, reason})
          final
        end)

      assert Machine.status_for(final.live.machine) == :idle
      assert log =~ "chat_crashed"
      assert is_nil(final.live.machine.work.active_worker)

      assert_receive {:chat_error, %{content: content}}
      assert content =~ "second consecutive"
    end

    test "a :cannot_compact append is tagged :invalid instead of raising" do
      # `context_limit: 1` makes `PreFlight.check_passed/2` return
      # `:cannot_compact` (the reserve alone exceeds the limit), which the
      # append path surfaces as a tagged `:invalid` rather than an
      # `ArgumentError`. No rows are inserted: the tripwire returns before
      # the append persists.
      state =
        state(unique_name("cannot-compact"), [system(0), user(1)])
        |> live(:streaming)
        |> with_limit(1)

      assert {:invalid, reason, _state} = MessageAppender.append_one(state, assistant_text(nil))
      assert reason =~ ":cannot_compact"

      # The trusted GenServer append call maps the same tripwire to an error
      # reply and fails the turn cleanly.
      {reply, log} =
        with_log(fn ->
          Callbacks.handle_call({:append_message, assistant_text(nil)}, nil, state)
        end)

      assert {:reply, {:error, ^reason}, _state} = reply
      assert log =~ "chat_crashed"
    end

    test "a live batch halts on the first stale and on the first invalid message" do
      name = unique_name("live-batch")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      stale_initial = [
        system(0),
        user(1),
        assistant_tool_use(2, "call_1"),
        tool_result(3, "call_1")
      ]

      insert_messages(name, stale_initial)
      stale_state = state(name, stale_initial) |> live(:streaming)

      {stale_result, stale_log} =
        with_log(fn ->
          MessageAppender.handle_batch(stale_state, [tool_result(nil, "call_1")])
        end)

      assert {:stale, ^stale_state} = stale_result
      assert stale_log =~ "dropping a stale append"

      invalid_name = unique_name("live-batch-invalid")
      {:ok, _} = Persistence.insert_agent(agent_attrs(invalid_name))
      invalid_initial = [system(0), user(1), assistant_text(2)]
      insert_messages(invalid_name, invalid_initial)
      invalid_state = state(invalid_name, invalid_initial) |> live(:streaming)

      assert {:invalid, reason, ^invalid_state} =
               MessageAppender.handle_batch(invalid_state, [assistant_text(nil)])

      assert reason =~ "second consecutive assistant"
    end

    test "the GenServer append call tags a stale result and fails an invalid append cleanly" do
      name = unique_name("callbacks-append")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      stale_initial = [
        system(0),
        user(1),
        assistant_tool_use(2, "call_1"),
        tool_result(3, "call_1")
      ]

      insert_messages(name, stale_initial)
      stale_state = state(name, stale_initial) |> live(:streaming)

      {stale_reply, stale_log} =
        with_log(fn ->
          Callbacks.handle_call({:append_message, tool_result(nil, "call_1")}, nil, stale_state)
        end)

      assert {:reply, :stale, ^stale_state} = stale_reply
      assert stale_log =~ "dropping a stale append"

      invalid_name = unique_name("callbacks-invalid")
      {:ok, _} = Persistence.insert_agent(agent_attrs(invalid_name))
      invalid_initial = [system(0), user(1), assistant_text(2)]
      insert_messages(invalid_name, invalid_initial)
      invalid_state = state(invalid_name, invalid_initial) |> live(:streaming)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{invalid_state.space_id}:#{invalid_name}")

      {reply, log} =
        with_log(fn ->
          Callbacks.handle_call({:append_message, assistant_text(nil)}, nil, invalid_state)
        end)

      assert {:reply, {:error, reason}, final} = reply
      assert reason =~ "second consecutive"
      assert Machine.status_for(final.live.machine) == :idle
      assert log =~ "chat_crashed"
      assert_receive {:chat_error, %{content: _}}
    end
  end

  describe "live stream failure tags" do
    test "the worker's llm_error callback fails the live turn to idle with chat:error" do
      name = unique_name("llm-error-invalid")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_text(2)]
      insert_messages(name, initial)
      ref = make_ref()

      state =
        state(name, initial)
        |> live(:streaming)
        |> put_in(
          [Access.key(:live), Access.key(:machine), Access.key(:work), Access.key(:worker_ref)],
          ref
        )

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{name}")

      {result, log} = with_log(fn -> Turn.handle({:llm_error, "boom"}, state) end)

      assert {:noreply, final} = result
      assert Machine.status_for(final.live.machine) == :idle
      assert log =~ "chat:error"
      assert_receive {:chat_error, %{content: content}}
      assert content =~ "boom"
    end
  end

  # ---- helpers (shared with `AppendPairingBridgeTest`) ----

  describe "the compaction request is not progress" do
    test "appending it does not reset the consecutive-compaction counter" do
      # The compaction request is a `:user` row — that is what every provider's
      # wire format can carry — so without a named origin the progress rule
      # would reset `loop_count` on every attempt and disarm
      # `@max_consecutive_compactions`, which is the only thing bounding a
      # compaction that keeps failing. `handle_single/2` is the entry point the
      # executor's `{:append, message}` action uses, so this is the real path.
      name = unique_name("compact-progress")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), assistant_text(1)]
      insert_messages(name, initial)
      before = length(Persistence.load_full_messages(test_space_id(), name))

      state = state(name, initial)
      state = %{state | live: %{state.live | machine: %{state.live.machine | loop_count: 3}}}

      request =
        {:user,
         %User{
           index: nil,
           parts: [%Part.Text{text: "[mode: compact] Summarize the conversation."}],
           metadata: User.compaction_metadata(),
           api_logs: []
         }}

      assert {:ok, _stamped, after_request} = MessageAppender.handle_single(state, request)
      assert after_request.live.machine.loop_count == 3

      # An ordinary human message *is* progress and does reset it — so the
      # assertion above is about the origin, not about the append being a
      # no-op.
      human =
        {:user,
         %User{
           index: nil,
           parts: [%Part.Text{text: "[mode: chat]\nhello"}],
           metadata: User.human_metadata(),
           api_logs: []
         }}

      assert {:ok, _stamped, after_human} = MessageAppender.handle_single(after_request, human)
      assert after_human.live.machine.loop_count == 0

      # ... and both appends really persisted, rather than only updating the
      # in-memory state. Without the fixture's `agent_row_id`,
      # `append_message/3` refuses every write with `:agent_row_reused` and
      # logs it, and the assertions above would still pass. Three rows land:
      # the request, and the bridge + human pair.
      assert length(Persistence.load_full_messages(test_space_id(), name)) == before + 3
    end

    test "appending the refused-batch heal does not reset the counter either" do
      # The heal row is emitted by the same transition that stages the
      # compaction request when `BatchSizer.preflight/2` refuses a batch — so
      # it is appended on *every* attempt of the automatic "compact, still
      # doesn't fit, refuse a batch, compact…" loop that
      # `@max_consecutive_compactions` exists to bound. It is a `{:tool, _}`,
      # which the progress rule counts as genuine progress, so without a
      # marker it resets the breaker exactly as the unmarked request row did.
      name = unique_name("heal-progress")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), assistant_text(1)]
      insert_messages(name, initial)
      before = length(Persistence.load_full_messages(test_space_id(), name))

      state = state(name, initial)
      state = %{state | live: %{state.live | machine: %{state.live.machine | loop_count: 2}}}

      # Built by production code, so the test cannot drift from the real shape.
      tool_uses = [
        %Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{}}
      ]

      heal = MessageList.interrupted_tool_result(tool_uses)
      assert {:ok, _stamped, after_heal} = MessageAppender.handle_single(state, heal)
      assert after_heal.live.machine.loop_count == 2

      # ... and it really persisted, so this is not passing on a refused write.
      assert length(Persistence.load_full_messages(test_space_id(), name)) == before + 1
    end
  end

  describe "the stop's cancellation record through the appender" do
    test "a deferred tail lands as tool → assistant(bridge) → user(notice) → assistant(ack)" do
      # The stop's record for a tail that carries an unpaired `tool_use` cannot
      # be built by `build_pair/3` — it answers `:deferred` there — so
      # `notice_record/3` lands the hand-built bridge shape. That shape is
      # wire-legal only because the appender repairs the tail per message
      # before the record's rows arrive, which is what this drives: the record
      # comes from the stop's own action list, not from a fixture.
      name = unique_name("stop-record-deferred")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [
        system(0),
        user(1),
        assistant_tool_use(2, "call_1"),
        tool_result(3, "call_1"),
        assistant_text(4),
        user(5),
        assistant_tool_use(6, "call_2")
      ]

      insert_messages(name, initial)

      # A backgrounded promise (so the stop emits a record at all) and a live
      # batch's assistant tail: the `:deferred` case.
      machine =
        Machine.new(
          phase: :executing_tools,
          kind: :chat,
          work: %Machine.Work{
            worker_kind: :tools,
            backgrounded: %{make_ref() => %{pid: self(), ids: ["call_1"]}},
            ctx: %{messages: initial}
          }
        )

      assert {:ok, actions, stopping} = Machine.step(machine, {:stop, self()})
      assert [{:append_many, record}] = Enum.filter(actions, &match?({:append_many, _}, &1))

      state = state(name, initial)
      state = %{state | live: %{state.live | machine: stopping}}

      assert {:ok, _stamped, landed} = MessageAppender.append_in_process(state, record)

      persisted = Persistence.load_messages(test_space_id(), name)
      roles = Enum.map(persisted, &elem(&1, 0))

      # `call_2` is the unpaired tail: the appender answers it, then the record's
      # three rows land — the notice on a `:user` row, between two assistants.
      assert Enum.take(roles, 7) == [
               :system,
               :user,
               :assistant,
               :tool,
               :assistant,
               :user,
               :assistant
             ]

      assert Enum.drop(roles, 7) == [:tool, :assistant, :user, :assistant]

      # In-memory and persisted agree, and the indices are contiguous.
      assert Enum.map(landed.chat_state.messages, &elem(&1, 0)) == roles
      assert Enum.map(persisted, &index/1) == Enum.to_list(0..10)

      assert {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_2", is_error: true}]}} =
               Enum.at(persisted, 7)

      assert {:user, %User{parts: [%Part.Text{text: notice}]}} = Enum.at(persisted, 9)
      assert notice =~ "cancelled when the conversation was stopped"

      # The alternation the whole change is about, judged by the real rule set.
      assert :ok = Preflight.validate(persisted)
    end
  end

  defp state(name, messages) do
    %Agent{
      name: name,
      space_id: test_space_id(),
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      chat_state: %Agent.ChatState{
        messages: messages,
        next_message_index: next_index(messages),
        agent_row_id: agent_row_id(name)
      }
    }
  end

  # The row this session was started from. `append_message/3` passes this as
  # `expect_agent_row_id`, and refuses a write whose name resolves to a
  # *different* row (`:agent_row_reused`) — so a fixture that leaves it `nil`
  # while a row exists drops and logs every append. A test that then asserted
  # on the in-memory state alone would pass while nothing was persisted.
  defp agent_row_id(name) do
    case Persistence.fetch_agent(test_space_id(), name) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp live(state, status) do
    %{
      state
      | live: %{
          state.live
          | machine: Machine.status_to_machine(state.live.machine, status)
        }
    }
  end

  defp with_limit(state, limit) do
    %{state | llm_metrics: %{state.llm_metrics | context_limit: limit}}
  end

  defp insert_messages(name, messages) do
    for message <- messages do
      {:ok, _} = Persistence.insert_message(test_space_id(), name, message)
    end
  end

  defp next_index([]), do: 0

  defp next_index(messages) do
    messages |> Enum.map(&index/1) |> Enum.max() |> Kernel.+(1)
  end

  defp index({_role, %{index: idx}}), do: idx

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(text) when is_binary(text),
    do: {:user, %User{index: nil, parts: [%Part.Text{text: text}]}}

  defp user(index), do: {:user, %User{index: index, parts: [%Part.Text{text: "hi"}]}}

  defp assistant_text(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool_use(index, id), do: assistant_tool_uses(index, [id])

  defp assistant_tool_uses(index, ids) do
    parts =
      Enum.map(ids, fn id ->
        %Part.ToolUse{id: id, name: "shell-cmd", arguments: %{"command" => "x"}}
      end)

    {:assistant, %Assistant{index: index, parts: parts, api_logs: []}}
  end

  defp tool_result(index, id) do
    {:tool,
     %Tool{
       index: index,
       parts: [
         %Part.ToolResult{tool_call_id: id, name: "shell-cmd", content: "ok", is_error: false}
       ],
       api_logs: []
     }}
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end

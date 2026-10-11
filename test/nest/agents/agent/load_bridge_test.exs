defmodule Nest.Agents.Agent.LoadBridgeTest do
  @moduledoc """
  Load-time enforcement of "an idle agent never ends on a user message".

  A persisted active slice that is wire-valid but ends on a `user` role
  (e.g. a crash between the user append and the first assistant delta,
  or a legacy compaction segment) is bridged at load: the load-specific
  assistant ack is appended and persisted before the agent comes up
  `:idle`. The trailing-orphan tool_use heal is unchanged.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.Agents.AgentTestHelpers

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.Supervisor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  setup do
    # `create_test_space/0` registers the per-test space id in the process
    # dictionary (`current_space_id/0` reads it back). No context key is
    # returned: every test re-derives the id.
    {:ok, _space_id} = create_test_space()
    :ok
  end

  describe "Repair.classify_load/1" do
    test "bridges a valid slice ending on a user role and leaves the rest unchanged" do
      assert {:bridge, [ack]} = Repair.classify_load([system(0), user(1, "hi")])
      assert {:assistant, %Assistant{parts: [%Part.Text{text: text}]}} = ack
      assert text =~ "interrupted"

      assert :ok = Repair.classify_load([system(0), user(1, "hi"), assistant_text(2)])
      assert :ok = Repair.classify_load([])
    end

    test "records a restored backgrounded promise as lost, once" do
      # The sequence a backgrounded batch leaves: the call, the machine's
      # synthetic answer (which promises the real result will arrive as a
      # message), and the ack. The promise is kept by the process that owns the
      # batch, so a restored transcript would keep promising a message that can
      # never come.
      tail = [
        system(0),
        user(1, "hi"),
        assistant_tool(2, "call_1"),
        tool_result(3, "call_1", "backgrounded"),
        assistant_text(4)
      ]

      assert {:lost_promises, [notice, ack]} = Repair.classify_load(tail)

      assert {:user, %User{parts: [%Part.Text{text: notice_text}]}} = notice
      assert notice_text =~ "lost when this agent restarted"
      assert notice_text =~ "Call it again if you still need it"

      assert {:assistant, %Assistant{parts: [%Part.Text{text: ack_text}], metadata: metadata}} =
               ack

      assert ack_text =~ "will not wait"
      assert metadata == %{"backgrounded_lost_ids" => ["call_1"]}

      # The record names the ids it voids, so re-classifying the healed tail
      # finds nothing left to record — `Init.LoadHeal.refresh/1` re-classifies
      # before appending, and a second record would repeat the same words.
      assert :ok = Repair.classify_load(tail ++ [notice, ack])

      # A `user` tail is covered by the same record (it lands as a lone
      # assistant, so the bridge is not needed): the model's last word is not
      # left waiting on a promise either way.
      user_tail = tail ++ [user(5, "and then?")]
      assert {:lost_promises, [record]} = Repair.classify_load(user_tail)
      assert {:assistant, %Assistant{parts: [%Part.Text{text: text}]}} = record
      assert text =~ "lost when this agent restarted"
      assert :ok = Repair.classify_load(user_tail ++ [record])

      # Two promises in one transcript: the record counts the *calls*, not the
      # result messages that carried them.
      two = [
        system(0),
        user(1, "hi"),
        assistant_tool(2, ["call_1", "call_2"]),
        tool_result(3, ["call_1", "call_2"], "backgrounded"),
        assistant_text(4)
      ]

      assert {:lost_promises, [{:user, %User{parts: [%Part.Text{text: two_text}]}}, _]} =
               Repair.classify_load(two)

      assert two_text =~ "The 2 backgrounded tool calls were lost"
    end

    test "records a promise in the same heal as a trailing orphan" do
      # A batch backgrounded, and then the delivered turn's own batch died
      # mid-tool: the slice carries an unfulfilled promise *and* a trailing
      # orphan. The orphan has to be answered before the record (the record is
      # built against a completed tail, and the whole heal is one append), so
      # both travel together. Recording only the orphan would leave the promise
      # unrecorded for the whole session that follows — the *next* load would be
      # the first to mention it, long after the model started waiting on it.
      active = [
        system(0),
        user(1, "hi"),
        assistant_tool(2, "call_1"),
        tool_result(3, "call_1", "backgrounded"),
        assistant_text(4),
        user(5, "and then?"),
        assistant_tool(6, "call_2")
      ]

      assert {:lost_promises, heal} = Repair.classify_load(active)

      assert [
               {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_2", is_error: true}]}},
               {:assistant, _ack},
               {:user, %User{parts: [%Part.Text{text: notice}]}},
               {:assistant, %Assistant{metadata: %{"backgrounded_lost_ids" => ["call_1"]}}}
             ] = heal

      assert notice =~ "lost when this agent restarted"

      # The healed tail classifies clean: the orphan is answered and the promise
      # is named, so a second load appends nothing.
      assert :ok = Repair.classify_load(active ++ heal)
    end
  end

  describe "build_attrs_for_start/2" do
    test "attaches the load bridge for a persisted user tail" do
      space_id = current_space_id()
      name = unique_name("user-tail")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))
      insert_messages(space_id, name, [system(0), user(1, "hi")])

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.sequence_violations == []

      assert {:bridge, [{:assistant, %Assistant{parts: [%Part.Text{text: text}]}}]} =
               attrs.load_heal

      assert text =~ "interrupted"
    end

    test "leaves a clean assistant tail and the trailing orphan unchanged" do
      space_id = current_space_id()

      clean = unique_name("clean")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, clean))
      insert_messages(space_id, clean, [system(0), user(1, "hi"), assistant_text(2)])

      assert {:ok, clean_attrs} = Persistence.build_attrs_for_start(space_id, clean)
      assert clean_attrs.load_heal == nil

      orphan = unique_name("orphan")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, orphan))
      insert_messages(space_id, orphan, [system(0), user(1, "hi"), assistant_tool(2, "call_1")])

      assert {:ok, orphan_attrs} = Persistence.build_attrs_for_start(space_id, orphan)
      assert [%Part.ToolUse{id: "call_1", name: "shell-cmd"}] = orphan_attrs.load_heal
    end

    test "attaches the lost-promise record for a restored backgrounded call" do
      space_id = current_space_id()
      name = unique_name("lost-promise")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))

      # Persisted through the JSON encoder, so this also pins that the
      # synthetic result's `state` survives the round trip: without it a
      # restored transcript is indistinguishable from a batch that answered.
      insert_messages(space_id, name, [
        system(0),
        user(1, "hi"),
        assistant_tool(2, "call_1"),
        tool_result(3, "call_1", "backgrounded"),
        assistant_text(4)
      ])

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.sequence_violations == []

      assert {:lost_promises, [{:user, %User{parts: [%Part.Text{text: notice}]}}, _]} =
               attrs.load_heal

      assert notice =~ "lost when this agent restarted"
    end
  end

  describe "Agent.pre_load_heal/1" do
    test "leaves attrs untouched when the model no longer resolves" do
      # Without a client config `init/1` boots in `:model_missing` and
      # never reaches the heal, so there is nothing to fold in.
      space_id = current_space_id()
      name = unique_name("pre-load-no-model")

      attrs = Map.put(agent_attrs(space_id, name), :model, %{name: "no-such-model-xyz"})
      {:ok, _} = Persistence.insert_agent(attrs)
      insert_messages(space_id, name, [system(0), user(1, "hi")])

      {:ok, start_attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert {:bridge, _} = start_attrs.load_heal
      assert Agent.pre_load_heal(start_attrs) == start_attrs
    end

    test "a second heal of the same tail appends nothing" do
      space_id = current_space_id()
      name = unique_name("heal-once")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))
      insert_messages(space_id, name, [system(0), user(1, "hi")])

      {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert {:bridge, _} = attrs.load_heal

      subscribe(space_id, name)

      log =
        capture_log(fn ->
          healed = Agent.pre_load_heal(attrs)
          assert healed.load_heal == nil

          assert Enum.map(healed.preloaded_messages, &elem(&1, 0)) ==
                   [:system, :user, :assistant]
        end)

      assert log =~ "idle sequence ending on a user message"

      # The bridge was appended once, at index 2, and broadcast once.
      assert_received {:chat_message, {:assistant, %Assistant{index: 2}}}

      assert persisted_sequence(space_id, name) == [{0, :system}, {1, :user}, {2, :assistant}]

      # A second caller holding the same pre-heal attrs must re-derive the
      # classification from a fresh read, see the healed tail, and append
      # nothing: no second row, no second broadcast. `capture_log` is here
      # only so a regression's heal warning doesn't print to the console.
      _ =
        capture_log(fn ->
          again = Agent.pre_load_heal(attrs)
          assert again.load_heal == nil

          assert Enum.map(again.preloaded_messages, &elem(&1, 0)) ==
                   [:system, :user, :assistant]

          refute_received {:chat_message, _}
        end)

      assert persisted_sequence(space_id, name) == [{0, :system}, {1, :user}, {2, :assistant}]
    end

    test "leaves attrs untouched when the agent row is gone" do
      space_id = current_space_id()
      name = unique_name("row-gone")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))
      insert_messages(space_id, name, [system(0), user(1, "hi")])

      {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert {:bridge, _} = attrs.load_heal

      subscribe(space_id, name)
      assert :ok = Persistence.delete_agent(space_id, name)

      # There is no persisted sequence left to heal, so the heal stays
      # pending on the attrs and nothing is appended or broadcast.
      assert Agent.pre_load_heal(attrs) == attrs
      refute_received {:chat_message, _}
      assert Persistence.load_messages(space_id, name) == []
    end

    test "concurrent fetch_or_start_agent/2 calls leave one healed sequence" do
      space_id = current_space_id()
      name = unique_name("concurrent-load")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))
      insert_messages(space_id, name, [system(0), user(1, "hi")])

      # Both callers may classify the same pre-heal tail and heal it (the
      # race this test pins), so their warnings are captured rather than
      # asserted on: which caller heals depends on how the two interleave.
      {results, _log} =
        with_log(fn ->
          1..2
          |> Enum.map(fn _ ->
            Task.async(fn -> Supervisor.fetch_or_start_agent(space_id, %{name: name}) end)
          end)
          |> Task.await_many()
        end)

      # Both callers get the agent: the one that loses the start race maps
      # `{:error, {:already_started, _}}` to `{:ok, name}`.
      assert results == [{:ok, name}, {:ok, name}]

      # One bridge row, one index, no duplicate ack — whichever way the two
      # callers interleave.
      assert persisted_sequence(space_id, name) == [{0, :system}, {1, :user}, {2, :assistant}]

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.status == :idle
    end
  end

  describe "Init.LoadHeal.heal/2" do
    test "appends and persists the load bridge before idling" do
      space_id = current_space_id()
      name = unique_name("heal-bridge")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))
      initial = [system(0), user(1, "hi")]
      insert_messages(space_id, name, initial)

      state = load_state(name, space_id, initial)

      log =
        capture_log(fn ->
          {:bridge, [ack]} = Repair.classify_load(initial)
          healed = Init.LoadHeal.heal(state, {:bridge, [ack]})

          assert {:assistant, %Assistant{parts: [%Part.Text{text: text}]}} =
                   List.last(healed.chat_state.messages)

          assert text =~ "interrupted"
        end)

      assert log =~ "idle sequence ending on a user message"

      # Persisted, so a subsequent load has nothing left to bridge.
      assert [:system, :user, :assistant] =
               Persistence.load_messages(space_id, name) |> Enum.map(&elem(&1, 0))

      assert {:ok, again} = Persistence.build_attrs_for_start(space_id, name)
      assert again.load_heal == nil
    end

    test "records a lost backgrounded promise, and the healed tail needs no second record" do
      space_id = current_space_id()
      name = unique_name("heal-lost-promise")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))

      initial = [
        system(0),
        user(1, "hi"),
        assistant_tool(2, "call_1"),
        tool_result(3, "call_1", "backgrounded"),
        assistant_text(4)
      ]

      insert_messages(space_id, name, initial)
      state = load_state(name, space_id, initial)

      log =
        capture_log(fn ->
          assert {:lost_promises, record} = Repair.classify_load(initial)
          healed = Init.LoadHeal.heal(state, {:lost_promises, record})

          # The promise is answered in the transcript: the model reads that the
          # call was lost rather than waiting for a message that cannot arrive.
          assert [{:user, %User{parts: [%Part.Text{text: notice}]}}, {:assistant, _}] =
                   Enum.take(healed.chat_state.messages, -2)

          assert notice =~ "lost when this agent restarted"
        end)

      assert log =~ "backgrounded tool result the restart lost"

      # Persisted, so the next load classifies clean: the record named the ids
      # it voided, which is what makes the heal idempotent (`refresh/1`
      # re-classifies the same tail before appending).
      assert [:system, :user, :assistant, :tool, :assistant, :user, :assistant] =
               Persistence.load_messages(space_id, name) |> Enum.map(&elem(&1, 0))

      assert {:ok, again} = Persistence.build_attrs_for_start(space_id, name)
      assert again.load_heal == nil
    end

    test "two callers that both pass the re-check derive the same append index" do
      space_id = current_space_id()
      name = unique_name("heal-race")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))
      initial = [system(0), user(1, "hi")]
      insert_messages(space_id, name, initial)

      # The same-instant interleaving `refresh/1` cannot rule out: two
      # callers both classify the same pre-heal tail, each build their state
      # from the same pre-heal attrs, and heal without re-reading. Both
      # derive the same append index; the unique `(agent_id, message_index)`
      # index plus `insert_message/3`'s `on_conflict: :nothing` drops the
      # loser's row, so the persisted sequence keeps one heal row and
      # neither caller holds a row the DB does not have.
      {:bridge, [ack]} = Repair.classify_load(initial)
      state_a = load_state(name, space_id, initial)
      state_b = load_state(name, space_id, initial)

      {{healed_a, healed_b}, log} =
        with_log(fn ->
          {Init.LoadHeal.heal(state_a, {:bridge, [ack]}),
           Init.LoadHeal.heal(state_b, {:bridge, [ack]})}
        end)

      assert log =~ "idle sequence ending on a user message"

      # One heal row, not two, at the index both appends derived (2).
      persisted = persisted_sequence(space_id, name)
      assert persisted == [{0, :system}, {1, :user}, {2, :assistant}]

      # `healed_b` is the assertion that carries the information: it is the
      # caller whose row the unique index dropped, so it is the one that
      # proves the loser's in-memory row still carries the `(index, role)`
      # the winner's did. `healed_a` is built from the same `initial` list
      # and the same `ack` as `state_a`, so its sequence is
      # `[{0, :system}, {1, :user}, {2, :assistant}]` by construction; it is
      # asserted anyway because the test's claim is that BOTH callers end up
      # consistent with the persisted row, not just the loser.
      assert in_memory_sequence(healed_a) == persisted
      assert in_memory_sequence(healed_b) == persisted
    end
  end

  # ---- helpers ----

  defp subscribe(space_id, name) do
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")
  end

  # The persisted sequence as `{index, role}` pairs, so one assertion pins
  # the roles, their order, and that no extra row was appended.
  defp persisted_sequence(space_id, name) do
    Persistence.load_messages(space_id, name)
    |> Enum.map(fn {role, %{index: index}} -> {index, role} end)
  end

  # The in-memory sequence as `{index, role}` pairs, mirroring
  # `persisted_sequence/2` so the two can be compared directly.
  defp in_memory_sequence(state) do
    Enum.map(state.chat_state.messages, fn {role, %{index: index}} -> {index, role} end)
  end

  defp load_state(name, space_id, messages) do
    %Agent{
      name: name,
      space_id: space_id,
      llm_metrics: %Agent.LlmMetrics{context_limit: 100_000, context_limit_source: :config},
      chat_state: %Agent.ChatState{messages: messages, next_message_index: length(messages)}
    }
  end

  defp agent_attrs(space_id, name) do
    %{
      space_id: space_id,
      name: name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      workspace_path: nil,
      vocation_id: vocation_id_for_test()
    }
  end

  defp insert_messages(space_id, name, messages) do
    for message <- messages do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end
  end

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index, text), do: {:user, %User{index: index, parts: [%Part.Text{text: text}]}}

  defp assistant_text(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool(index, id) when is_binary(id), do: assistant_tool(index, [id])

  defp assistant_tool(index, ids) do
    parts = Enum.map(ids, &%Part.ToolUse{id: &1, name: "shell-cmd", arguments: %{}})

    {:assistant, %Assistant{index: index, parts: parts, api_logs: []}}
  end

  # A tool result, `state` included: `"backgrounded"` is the machine's synthetic
  # answer to a call it moved to the background (issue #36), and it is what
  # `MessageList.backgrounded_results/1` keys on.
  defp tool_result(index, id, state) when is_binary(id), do: tool_result(index, [id], state)

  defp tool_result(index, ids, state) do
    {:tool,
     %Tool{index: index, parts: Enum.map(ids, &backgrounded_part(&1, state)), api_logs: []}}
  end

  defp backgrounded_part(id, state) do
    %Part.ToolResult{
      tool_call_id: id,
      name: "shell-cmd",
      arguments: %{},
      content:
        "The shell-cmd call was moved to the background; its result " <>
          "will arrive later as a message.",
      is_error: false,
      state: state
    }
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end

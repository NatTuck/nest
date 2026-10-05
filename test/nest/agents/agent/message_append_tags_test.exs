defmodule Nest.Agents.Agent.MessageAppendTagsTest do
  @moduledoc """
  Step 6 of `notes/continue.md`: no-crash appends + the single repair
  decision.

  `MessageAppender` returns `{:ok, stamped, state} | {:stale, state} |
  {:invalid, reason, state}` and never raises on a sequence mismatch.
  `Nest.Agents.Agent.Repair.decide/3` is the one decision table; the
  live context classifies (no repair), the terminal/worker-death/load
  contexts heal. These tests pin the `Repair` decision table and the
  caller behavior for `:stale` (drop with a notice) and `:invalid` (fail
  the turn to idle with `chat:error`).
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Callbacks
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler
  alias Nest.Agents.Agent.Handlers.TurnHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.Repair
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  describe "Repair.decide/3" do
    test ":live classifies ok, stale, and invalid without repairing" do
      assert :ok = Repair.decide(:live, [user(0)], assistant_text(1))

      assert :stale = Repair.decide(:live, [assistant_tool_use(0, "a")], tool_result(1, "b"))

      assert {:invalid, reason} =
               Repair.decide(:live, [assistant_tool_use(0, "a")], user(1))

      assert reason =~ "live tool_use"

      assert {:invalid, reason} =
               Repair.decide(:live, [user(0), assistant_text(1)], assistant_text(2))

      assert reason =~ "second consecutive assistant"
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

    test ":load classifies clean, interrupted, and real violations" do
      assert :ok = Repair.decide(:load, [system(0), user(1), assistant_text(2)], nil)

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

      {final, log} = with_log(fn -> TurnHandler.invalid_append_state(state, reason) end)

      assert Machine.status_for(final.live.machine) == :idle
      assert log =~ "chat_crashed"
      assert is_nil(final.live.machine.work.ctx)

      assert_receive {:chat_error, %{content: content}}
      assert content =~ "second consecutive"
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

  describe "LLMStreamHandler live append tags" do
    test "a tool-call append on a broken live tail fails the turn to idle" do
      name = unique_name("llm-tool-calls-invalid")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_text(2)]
      insert_messages(name, initial)
      state = state(name, initial) |> live(:streaming)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{name}")

      {:assistant, msg} = assistant_text(nil)

      {result, log} = with_log(fn -> LLMStreamHandler.tool_calls_received(msg, state) end)

      assert {:noreply, final} = result
      assert Machine.status_for(final.live.machine) == :idle
      assert log =~ "chat_crashed"
      assert_receive {:chat_error, %{content: _}}
    end

    test "an error append on a broken live tail fails the turn to idle" do
      name = unique_name("llm-error-invalid")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_text(2)]
      insert_messages(name, initial)
      state = state(name, initial) |> live(:streaming)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{name}")

      {final, log} = with_log(fn -> LLMStreamHandler.llm_error_state("boom", state) end)

      assert Machine.status_for(final.live.machine) == :idle
      assert log =~ "chat_crashed"
      assert_receive {:chat_error, %{content: _}}
    end
  end

  # ---- helpers (shared with `AppendPairingBridgeTest`) ----

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
      chat_state: %Agent.ChatState{messages: messages, next_message_index: next_index(messages)}
    }
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

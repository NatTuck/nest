defmodule Nest.Agents.Agent.ClientAPITest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.ClientAPI` — the convenience
  get_* wrappers extracted from `Nest.Agents.Agent` so the
  GenServer module stays under the credo 500-line cap.

  Each function is a one-line `GenServer.call` that
  forwards to `IntrospectionHandler.handle/3`. These
  tests pin each call shape against a live agent so the
  wrapper is genuinely exercised (not just defined).
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent.ClientAPI
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    # The DataCase's automatic sandbox rollback covers
    # the agent rows (`Agents.create_agent/2`'s pre_spawn
    # insert is rolled back). A `for id <- ...;
    # delete_agent(id)` here would deadlock on
    # `DBConnection.OwnershipError` because `on_exit`
    # runs in `ExUnit.OnExitHandler`'s runner process
    # — no sandbox ownership. The same pattern is
    # documented in `agent_file_policy_test.exs`.
    on_exit(fn ->
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  describe "get_public_info/1" do
    test "returns the agent's full public info map" do
      {pid, name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
      _ref = Process.monitor(pid)

      info = ClientAPI.get_public_info(pid)
      assert info.name == name
      assert model_name(info.model) == "qwen3.5-plus"
      assert info.status == :idle
    end
  end

  describe "get_messages/1" do
    test "returns the system prompt only for a fresh agent" do
      {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})

      messages = ClientAPI.get_messages(pid)
      # A fresh agent hydrates the immutable initial system
      # message (position 0). The wrapper just delegates to
      # the IntrospectionHandler, so this is enough to
      # cover the wrapper surface.
      assert length(messages) == 1
      assert match?({:system, _}, hd(messages))
    end
  end

  describe "get_history/1" do
    test "returns an empty list when no compaction has run" do
      {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})

      assert ClientAPI.get_history(pid) == []
    end
  end

  describe "get_total_usage/1" do
    test "returns the zero-totals placeholder before any LLM call" do
      {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})

      totals = ClientAPI.get_total_usage(pid)
      assert is_map(totals)
      assert totals.input_tokens == 0
      assert totals.output_tokens == 0
    end
  end

  describe "get_chat_turn_pid/1" do
    test "returns nil when the agent is idle" do
      {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})

      assert ClientAPI.get_chat_turn_pid(pid) == nil
    end
  end

  describe "terminate/1" do
    test "stops the agent process" do
      {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
      ref = Process.monitor(pid)
      assert Process.alive?(pid)

      :ok = ClientAPI.terminate(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end
  end

  defp model_name(model), do: model[:name] || model["name"]
end

defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Agent lifecycle tests: `start_link/1`.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Registry
  alias Nest.Messages.Assistant
  alias Nest.Messages.{Tool, User}
  # `System` left unaliased to avoid shadowing Elixir.System.

  describe "start_link/1" do
    test "starts agent and registers in registry" do
      agent_name = "registered-agent-#{System.unique_integer([:positive])}"

      # `vocation_id` is required by the schema, but this test
      # has no DataCase (and therefore no sandboxed DB
      # connection). The integer is a sentinel — the no-
      # persistence path never dereferences it; the
      # `vocation: nil` short-circuits the system-prompt
      # composition to a minimal default.
      pid =
        start_supervised!(
          {Agent,
           %{
             name: agent_name,
             model: %{name: "qwen3.5-plus"},
             vocation_id: 0,
             vocation: nil
           }}
        )

      assert Registry.lookup(agent_name) == {:ok, pid}
    end
  end

  describe "consecutive_compaction_count reset on append_message" do
    test "appending :user, :assistant, or :tool messages resets to 0" do
      agent_name = "loop-counter-agent-#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Agent,
           %{
             name: agent_name,
             model: %{name: "qwen3.5-plus"},
             vocation_id: 0,
             vocation: nil
           }}
        )

      # Bump the counter out-of-band via the GenServer API.
      :ok = GenServer.call(pid, {:set_consecutive_compaction_count, 5})

      user_msg = {:user, %User{parts: [], index: nil}}
      assistant_msg = {:assistant, %Assistant{parts: [], index: nil}}
      tool_msg = {:tool, %Tool{parts: [], index: nil}}
      system_msg = {:system, %Nest.Messages.System{parts: [], index: nil}}
      compaction_msg = {:compaction, %{parts: [], index: nil}}

      for msg <- [user_msg, assistant_msg, tool_msg] do
        GenServer.call(pid, {:set_consecutive_compaction_count, 5})
        _ = GenServer.call(pid, {:append_message, msg})
        after_count = GenServer.call(pid, :get_consecutive_compaction_count)
        assert after_count == 0, "expected reset after appending #{inspect(elem(msg, 0))}"
      end

      # `:system` and `:compaction` appends do NOT reset.
      for msg <- [system_msg, compaction_msg] do
        GenServer.call(pid, {:set_consecutive_compaction_count, 5})
        _ = GenServer.call(pid, {:append_message, msg})
        after_count = GenServer.call(pid, :get_consecutive_compaction_count)
        assert after_count == 5, "expected NO reset after appending #{inspect(elem(msg, 0))}"
      end
    end
  end
end

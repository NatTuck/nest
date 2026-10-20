defmodule Nest.Agents.AgentTest do
  @moduledoc """
  The loop-breaker counter's append-path branches: an `:assistant` append is
  progress and resets it, a `:system` append is not progress and does not.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.Assistant
  alias Nest.Messages.System, as: MsgSystem

  describe "consecutive_compaction_count on append_message" do
    test "an :assistant append resets it, a :system append does not" do
      {pid, _name} =
        AgentTestHelpers.start_agent(%{
          name: "loop-counter-agent-#{System.unique_integer([:positive])}"
        })

      :ok = GenServer.call(pid, {:set_consecutive_compaction_count, 5})
      _ = GenServer.call(pid, {:append_message, {:assistant, %Assistant{parts: [], index: nil}}})
      assert GenServer.call(pid, :get_consecutive_compaction_count) == 0

      :ok = GenServer.call(pid, {:set_consecutive_compaction_count, 5})
      _ = GenServer.call(pid, {:append_message, {:system, %MsgSystem{parts: [], index: nil}}})
      assert GenServer.call(pid, :get_consecutive_compaction_count) == 5
    end
  end
end

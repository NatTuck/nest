defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Agent lifecycle tests: `start_link/1`.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Registry

  describe "start_link/1" do
    test "starts agent and registers in registry" do
      agent_name = "registered-agent-#{System.unique_integer([:positive])}"

      pid =
        start_supervised!({Agent, %{name: agent_name, model: %{name: "qwen3.5-plus"}}})

      assert Registry.lookup(agent_name) == {:ok, pid}
    end
  end
end

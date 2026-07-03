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
end

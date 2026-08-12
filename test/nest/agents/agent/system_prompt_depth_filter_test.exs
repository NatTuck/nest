defmodule Nest.Agents.Agent.SystemPromptDepthFilterTest do
  @moduledoc """
  Tests for the system prompt's identity line and the
  (now removal) depth-based `agents/spawn` tool filtering.

  ## What's covered

  * The `[Delegation]` section is gone from the system prompt —
    tool descriptions in the tool list are the only guidance.
  * `compose_vocation_config/5` always returns the full
    vocation tool list regardless of depth (clones must keep
    the parent's exact tool list).
  * The identity line reports the agent's name and depth.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Vocations

  setup do
    valid_caps = %{
      "net" => false,
      "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
    }

    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "DepthFilter-#{System.unique_integer([:positive])}",
        description: "Depth filter test",
        system_prompt: "Base.",
        tools: ["agents/spawn", "context"],
        modes: %{
          "chat" => %{
            "description" => "General conversation.",
            "caps" => valid_caps
          }
        }
      })

    {:ok, vocation: vocation}
  end

  test "the system prompt has no [Delegation] section", %{vocation: vocation} do
    {prompt, _mode, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, "root", 0)

    refute prompt =~ "[Delegation]"
  end

  test "tool list is the full vocation list at any depth (clone hard rule)",
       %{vocation: vocation} do
    max = Config.configured_max_depth()

    for depth <- [0, max - 1, max, max + 1] do
      {_prompt, _mode, tools, _vocation} =
        SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, "agent", depth)

      assert "agents/spawn" in tools
      assert "context" in tools
    end
  end

  test "the identity line reports the agent's name and depth", %{vocation: vocation} do
    max = Config.configured_max_depth()

    {prompt, _mode, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, "clever-raven", 2)

    assert prompt =~ ~s(Your name is "clever-raven")
    assert prompt =~ "at spawn depth 2 of #{max}"
  end

  test "the identity line carries a caveat that it may change when cloned",
       %{vocation: vocation} do
    {prompt, _mode, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, "bob", 1)

    assert prompt =~ "may change when cloned"
  end

  test "query/list/archive tools still appear in the tool list", %{vocation: vocation} do
    tools_vocation = %{
      vocation
      | tools: ["agents/spawn", "agents/query", "agents/list", "agents/archive"]
    }

    {_prompt, _mode, tools, _vocation} =
      SystemPrompt.compose_vocation_config(tools_vocation, nil, {nil, nil}, "agent", 0)

    assert "agents/spawn" in tools
    assert "agents/query" in tools
    assert "agents/list" in tools
    assert "agents/archive" in tools
  end
end

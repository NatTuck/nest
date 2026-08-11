defmodule Nest.Agents.Agent.SystemPromptDepthFilterTest do
  @moduledoc """
  Tests for the depth-based filtering of the
  `agents/spawn` tool in the agent's system prompt.

  ## What's covered

    * At `depth < max_depth`, the prompt's `[Delegation]`
      section appears AND `agents/spawn` is in the tool list.
    * At `depth == max_depth`, neither appears.
    * The filter is data-driven from
      `DotConfig.configured_max_depth/0` (default 3).

  These assertions cover the contract that decides
  whether an agent can spawn children. The full call
  flow is exercised by `clone_agent_flow_test.exs`.
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

  test "root agent (depth 0) gets the [Delegation] section and agents/spawn in tools",
       %{vocation: vocation} do
    {prompt, _mode, tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, 0)

    assert "agents/spawn" in tools
    assert prompt =~ "[Delegation]"
    assert prompt =~ "agents/spawn"
  end

  test "intermediate agent (depth < max_depth) still gets the tool",
       %{vocation: vocation} do
    max = Config.configured_max_depth()

    if max > 1 do
      {_prompt, _mode, tools, _vocation} =
        SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, max - 1)

      assert "agents/spawn" in tools
    else
      # max = 1 → only depth 0 agents get the tool. Skip.
      :ok
    end
  end

  test "leaf agent (depth == max_depth) does NOT get agents/spawn or the [Delegation] section",
       %{vocation: vocation} do
    max = Config.configured_max_depth()

    {prompt, _mode, tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, max)

    refute "agents/spawn" in tools
    refute prompt =~ "[Delegation]"
  end

  test "beyond max_depth (off-by-one safety) also strips agents/spawn",
       %{vocation: vocation} do
    max = Config.configured_max_depth()

    {_prompt, _mode, tools, _vocation} =
      SystemPrompt.compose_vocation_config(vocation, nil, {nil, nil}, max + 1)

    refute "agents/spawn" in tools
  end

  test "a vocation with agents/query + agents/list documents them in the [Delegation] section",
       %{vocation: vocation} do
    tools_vocation = %{vocation | tools: ["agents/spawn", "agents/query", "agents/list"]}

    {prompt, _mode, tools, _vocation} =
      SystemPrompt.compose_vocation_config(tools_vocation, nil, {nil, nil}, 0)

    assert "agents/spawn" in tools
    assert "agents/query" in tools
    assert "agents/list" in tools
    assert prompt =~ "[Delegation]"
    assert prompt =~ "`agents/spawn`"
    assert prompt =~ "`agents/query`"
    assert prompt =~ "`agents/list`"
  end
end

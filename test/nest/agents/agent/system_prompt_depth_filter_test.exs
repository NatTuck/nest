defmodule Nest.Agents.Agent.SystemPromptDepthFilterTest do
  @moduledoc """
  Tests for the system prompt's identity line and the
  (now removal) depth-based `agents-spawn` tool filtering.

  ## What's covered

  * The `[Delegation]` section is gone from the system prompt —
    tool descriptions in the tool list are the only guidance.
  * `compose_vocation_config/6` always returns the full
    vocation tool list regardless of depth (clones must keep
    the parent's exact tool list).
  * The identity line reports the agent's name and depth.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox.Mounts
  alias Nest.Vocations

  setup do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "DepthFilter-#{System.unique_integer([:positive])}",
        description: "Depth filter test",
        system_prompt: "Base.",
        tools: ["context", "agents"]
      })

    {:ok, vocation: vocation}
  end

  # Compose the way the application does, with this suite's own mounts: no
  # workspace and no scratch, so none of the sections here reads a file and the
  # mode only decides the caps such a read would be authorized with. The
  # composer's argument order is
  # `(vocation, mounts, context_limit_info, name, depth, mode)`.
  defp compose(vocation, name, depth) do
    SystemPrompt.compose_vocation_config(
      vocation,
      Mounts.new(nil, nil),
      {nil, nil},
      name,
      depth,
      nil
    )
  end

  test "the system prompt has no [Delegation] section", %{vocation: vocation} do
    {prompt, _tools, _vocation} = compose(vocation, "root", 0)

    refute prompt =~ "[Delegation]"
  end

  test "tool list is the full vocation list at any depth (clone hard rule)",
       %{vocation: vocation} do
    max = Config.configured_max_depth()

    for depth <- [0, max - 1, max, max + 1] do
      {_prompt, tools, _vocation} = compose(vocation, "agent", depth)

      assert "agents-spawn" in tools
      assert "context-check" in tools
      assert "context-compact" in tools
    end
  end

  test "the identity line reports the agent's name and depth", %{vocation: vocation} do
    max = Config.configured_max_depth()

    {prompt, _tools, _vocation} = compose(vocation, "clever-raven", 2)

    assert prompt =~ ~s(Your name is "clever-raven")
    assert prompt =~ "at spawn depth 2 of #{max}"
  end

  test "the identity line carries a caveat that it may change when cloned",
       %{vocation: vocation} do
    {prompt, _tools, _vocation} = compose(vocation, "bob", 1)

    assert prompt =~ "may change when cloned"
  end

  test "states the agent's own scratch directory in the sandbox spelling",
       %{vocation: vocation} do
    {prompt, _tools, _vocation} = compose(vocation, "clever-raven", 0)

    # The space dir is bound at /tmp, so the agent's own dir is
    # /tmp/<name>. Stated here, once, instead of in every path-taking
    # tool description.
    assert prompt =~ "Your own scratch directory is `/tmp/clever-raven/`"
    assert prompt =~ "shared with your siblings"

    # The host backing path (`/tmp/nest/<ospid>/space-<id>/...`) must never
    # appear in the prompt. The root itself is the thing to look for: `"nest-"`
    # would pass vacuously, because the new host root is `/tmp/nest/<pid>`.
    refute prompt =~ TmpSpace.own_root()
  end

  test "omits the scratch section when there is no name", %{vocation: vocation} do
    {prompt, _tools, _vocation} = compose(vocation, "", 0)

    # The modes catalog mentions "your own scratch directory" too, so the
    # assertion is the section's own sentence, not the phrase.
    refute prompt =~ "Your own scratch directory is"
  end

  test "query/list/archive tools still appear in the tool list", %{vocation: vocation} do
    tools_vocation = %{
      vocation
      | tools: ["agents"]
    }

    {_prompt, tools, _vocation} = compose(tools_vocation, "agent", 0)

    assert "agents-spawn" in tools
    assert "agents-query" in tools
    assert "agents-list" in tools
    assert "agents-archive" in tools
  end
end

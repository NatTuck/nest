defmodule Nest.Agents.Agent.SystemPromptDepthFilterTest do
  @moduledoc """
  Tests for the system prompt's scratch section and the (now removed)
  depth-based `agents-spawn` tool filtering.

  ## What's covered

  * The `[Delegation]` section is gone from the system prompt —
    tool descriptions in the tool list are the only guidance.
  * `compose_vocation_config/6` never filters the spawn tool by
    depth (clones must keep the parent's exact tool list).
  * The scratch section says the `/tmp` root is shared with
    siblings and never names the host backing path.
  * The scratch section is omitted when there is no name.

  The identity line's name and depth, and the clone caveat, are pinned
  elsewhere: `AgentSpawnDepthPromptTest` (the start path),
  `AgentNameMigrationTest` / `LowercaseNamesMigrationTest` (the composer's
  exact renderings) and `AgentSystemPromptCompositionTest` (the caveat).
  Tool-group expansion is `Nest.Tools.GroupsTest`'s.
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

  test "the spawn tool survives at any depth (clone hard rule)", %{vocation: vocation} do
    max = Config.configured_max_depth()

    # Below the limit, at it, and past it: the composer has no depth branch, so
    # a re-introduced filter would show up at the boundary.
    for depth <- [0, max, max + 1] do
      {_prompt, tools, _vocation} = compose(vocation, "agent", depth)

      assert "agents-spawn" in tools
    end
  end

  test "the scratch section says the /tmp root is shared and never names the host path",
       %{vocation: vocation} do
    {prompt, _tools, _vocation} = compose(vocation, "clever-raven", 0)

    # The `/tmp/<name>/` spelling is pinned by the two name-migration suites,
    # which compose the prompt and then assert the rewritten text; what only
    # this test pins is the sentence that tells the agent the root is shared.
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
end

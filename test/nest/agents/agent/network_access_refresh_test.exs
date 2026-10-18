defmodule Nest.Agents.Agent.NetworkAccessRefreshTest do
  @moduledoc """
  The space's `network_access` is editable, and it rides the agent's `Mounts` —
  which are built once, at start. `Agent.update_environment/2` is the cast that
  tells a live agent, so the space's own claim that a change takes effect for its
  agents' subsequent commands is true.

  The mounts and the tool closures built from them move together (the closures
  capture the mounts), and a turn in flight picks the new value up at its next
  settle, because `Turn.build_ctx/2` re-reads the mounts. `Nest.Spaces` owns the
  push; this file owns what the agent does with it.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Sandbox.Mounts

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "the cast moves the mounts, the tool closures and the resolved caps together" do
    # The programmer vocation's tools include the ones that capture the mounts
    # (`file-*`, `shell-cmd`), which is what makes the closure rebuild
    # observable: a context tool captures nothing.
    {pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: AgentTestHelpers.programmer_vocation_id_for_test()
      })

    # allowlist: snapshot — the mounts and the tool closures built from them;
    # the fields the cast moves have no accessor.
    before = :sys.get_state(pid, 1_000)

    assert Mounts.network_access(before.mounts) == true
    assert Turn.build_ctx(before).caps["net"] == true

    :ok =
      Agent.space_changed(pid, %{
        workspace_path: Mounts.workspace(before.mounts),
        network_access: false,
        sandbox_backend: Mounts.backend(before.mounts)
      })

    # allowlist: barrier — synchronize the cast before reading the fields it
    # moves (there is no event frame to wait on), and read them: the mounts and
    # the closures have no accessor.
    after_cast = :sys.get_state(pid, 1_000)

    assert Mounts.network_access(after_cast.mounts) == false

    # The tool closures capture the mounts, so the refresh has to rebuild them —
    # the same tool set, from the new mounts.
    assert Enum.map(after_cast.tools, & &1.name) == Enum.map(before.tools, & &1.name)
    refute after_cast.tools == before.tools

    # ...and a turn's context re-reads the mounts, which is what makes the
    # change apply at the next settle rather than only for a future agent.
    assert Turn.build_ctx(after_cast).caps["net"] == false
  end
end

defmodule Nest.Agents.Agent.SpaceNetworkAccessTest do
  @moduledoc """
  The space's network access reaches the agents that are already running, and
  only that space's.

  `spaces.network_access` is carried on an agent's `Nest.Sandbox.Mounts`, which
  is what its caps are resolved from and what its tool closures were built with
  — so `Nest.Spaces.update_environment/2` has to hand the new value to every
  live agent in the space. Without that push a live agent would keep the value
  it started with until it was restarted, which is the hole this closes.

  Two things are pinned here and nowhere else: that the value the edit wrote
  lands on a live agent's mounts, in both directions, and that the rebuild the
  push triggers keeps the agent's tool set. `NetworkAccessRefreshTest` pins that
  the closures are new ones and that a turn's context resolves the new caps;
  `NetworkAccessNoticeTest` pins that the value reaches the notice the agent is
  told.

  The observation is the agent's own state, because neither half of what moves
  has a public accessor (`get_public_info/1` reports the mode and the workspace,
  not the caps) and the cast emits no frame to wait on. See `state/1`.
  """
  use Nest.DataCase, async: true

  import Nest.Agents.AgentTestHelpers

  alias Nest.Sandbox.Mounts
  alias Nest.Spaces

  test "a live agent's mounts move to the space's new value, and its tools are rebuilt" do
    {pid, _name} = start_agent()
    space_id = current_space_id()

    # The rebuild has to keep the agent's tools: the handler re-derives them from
    # `state.tools`' names, so a change here would silently strip the agent. The
    # emptiness check is what stops the comparison below from being vacuous.
    names = tool_names(pid)
    assert names != []
    assert network_access(pid) == true

    assert {:ok, _space} = Spaces.update_environment(space_id, %{network_access: false})
    assert network_access(pid) == false
    assert tool_names(pid) == names

    # Back on, so the mounts are pinned to the space's value rather than to the
    # literal `false` an implementation could hardcode.
    assert {:ok, _space} = Spaces.update_environment(space_id, %{network_access: true})
    assert network_access(pid) == true
  end

  test "leaves another space's agents on their own value" do
    {pid, _name} = start_agent()
    first_space_id = current_space_id()

    # A second `start_agent/0` puts its agent in a space of its own.
    {other_pid, _other_name} = start_agent()

    assert {:ok, _space} = Spaces.update_environment(first_space_id, %{network_access: false})

    # The control: the edit did reach the space it was made in. Without it the
    # line below would pass on an edit that reached nobody.
    assert network_access(pid) == false
    assert network_access(other_pid) == true
  end

  defp network_access(pid), do: Mounts.network_access(state(pid).mounts)

  defp tool_names(pid), do: Enum.map(state(pid).tools, & &1.name)

  # The agent's whole state, read because the two fields under test are not in
  # `get_public_info/1` and the cast that moves them emits no frame — so there is
  # no accessor to call and no event to wait for, and the read is also what makes
  # the cast's ordering observable (a read of the state sees every message the
  # agent had already handled).
  #
  # allowlist: barrier — the mounts have no accessor and the cast broadcasts nothing
  defp state(pid), do: :sys.get_state(pid)
end

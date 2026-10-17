defmodule Nest.Agents.Agent.NetworkAccessNoticeTest do
  @moduledoc """
  A live `network_access` flip reaches the agent twice over, and the two halves
  are pinned together so they cannot drift:

    * the **mounts** move, so the tool closures the agent will call next are built
      from the new value (`Nest.Agents.Agent.SpaceNetworkAccessTest` covers that
      half across two spaces and the tool rebuild);
    * the agent is **told**, by a `[Nest notice]` naming the new value — because
      the system prompt's network sentence was composed from the value the agent
      started with and is deliberately never rebuilt.

  The notice is *queued*, not appended: appending it would mean draining, and
  draining starts a turn, so a space-wide toggle would cost one LLM call per live
  agent. Queued is also what a peer's mode notice does, and the agent learns it at
  the start of its next turn — which is when it can act on it.

  The prompt-bytes assertion is the one that protects the project's cache rule:
  once a conversation is active the system message does not change except on
  compaction or a user-initiated model change. A "fix" that re-rendered the
  sentence would make it current and destroy prefix caching, which is a worse
  trade than a sentence that says what was true when the session started — so the
  sentence stays as composed, and the notice is what keeps the agent up to date.
  (Rewording the sentence to say "as of session start" was tried and backed out:
  `TurnBatchStartDeliveryTest` derives its context limit from the prompt's own
  size, so growing the prompt silently changed which side of the limit a
  delivery landed on. The sentence is true when it is composed; the notice is
  what makes it stay true.)
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Sandbox.Mounts
  alias Nest.Spaces

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    :ok
  end

  test "a live flip tells the agent and leaves the prompt's bytes alone" do
    {pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    prompt = AgentTestHelpers.get_system_prompt(pid)
    assert prompt =~ "Network access is enabled for this space"

    # Off.
    assert {:ok, _space} = Spaces.set_network_access(space_id, false)

    # The value the tools will actually run under moved...
    assert network_access(pid) == false
    # ...the agent was told what it is now...
    assert [off_notice] = notices(pid)
    assert off_notice =~ "Network access for this space is now disabled"
    assert off_notice =~ "the sandbox blocks your commands"
    # ...and the prompt did not. This is the cache rule, pinned.
    assert AgentTestHelpers.get_system_prompt(pid) == prompt

    # Back on, so the notice is not a one-way message.
    assert {:ok, _space} = Spaces.set_network_access(space_id, true)

    assert network_access(pid) == true
    # Nothing drained the queue, so both notices are still waiting — the off one
    # unchanged, the on one behind it.
    assert [^off_notice, on_notice] = notices(pid)
    assert on_notice =~ "Network access for this space is now enabled"
    assert on_notice =~ "your commands can reach the network"
    assert AgentTestHelpers.get_system_prompt(pid) == prompt
  end

  # The runtime notices waiting in the agent's inbox. `pending_messages` is
  # `Inbox.serialize/1`, so this is the same value the UI shows — the notice is
  # visible to the operator as well as queued for the model.
  defp notices(pid) do
    pid
    |> Agent.get_public_info(1_000)
    |> Map.fetch!(:pending_messages)
    |> Enum.map(&Map.fetch!(&1, "content"))
    |> Enum.filter(&(&1 =~ "[nest notice]"))
  end

  defp network_access(pid), do: Mounts.network_access(state(pid).mounts)

  # The mounts are not in `get_public_info/1`, and the `:set_network_access` cast
  # emits no frame of its own, so the value the tools were rebuilt from is only in
  # the state. Reading it also drains the cast, which is what orders the
  # assertions above rather than racing them.
  #
  # allowlist: barrier — the mounts have no accessor and the cast broadcasts nothing
  defp state(pid), do: :sys.get_state(pid)
end

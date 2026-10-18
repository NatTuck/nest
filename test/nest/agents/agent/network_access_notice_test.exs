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

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
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
    assert {:ok, _space} = Spaces.update_environment(space_id, %{network_access: false})

    # The value the tools will actually run under moved...
    assert network_access(pid) == false
    # ...the agent was told what it is now...
    assert [off_notice] = notices(pid)
    assert off_notice =~ "Network access: disabled"
    assert off_notice =~ "The `plan` restriction is enforced here"
    # ...and the prompt did not. This is the cache rule, pinned.
    assert AgentTestHelpers.get_system_prompt(pid) == prompt

    # Back on, so the notice is not a one-way message.
    assert {:ok, _space} = Spaces.update_environment(space_id, %{network_access: true})

    assert network_access(pid) == true
    # Both notices are in the transcript, in order: the pair is appended, so
    # nothing had to drain an inbox to get them there.
    assert [^off_notice, on_notice] = notices(pid)
    assert on_notice =~ "Network access: enabled"
    assert AgentTestHelpers.get_system_prompt(pid) == prompt
  end

  test "on a `none` space the notice does not claim a sandbox the space does not have" do
    # `none` runs the bare command on the host, so a "disabled" flip restricts
    # nothing. The prompt's sentence already says so
    # (`SystemPrompt.network_sentence("none", …)`), and the notice is built from
    # the same fact — otherwise the two halves of one change contradict each
    # other, and the agent is told its commands are blocked when they are not.
    {:ok, space_id} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
    AgentTestHelpers.put_space_id(space_id)
    name = "agent#{System.unique_integer([:positive])}"

    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    AgentTestHelpers.ensure_cleanup(name)
    {:ok, pid} = Supervisor.get_agent(space_id, name)

    # The agent clears its own `space_notice_pending` flag as it appends, so its
    # pid needs the test's sandbox connection — `start_agent/1` does this for the
    # agents it starts, and this test starts one through `Agents.create_agent/3`.
    Sandbox.allow(Nest.Repo, self(), pid)

    assert {:ok, _space} = Spaces.update_environment(space_id, %{network_access: false})

    assert [notice] = notices(pid)
    assert notice =~ "Network access: disabled"
    assert notice =~ "not enforced on this backend"
    refute notice =~ "is enforced here"
  end

  # The runtime notices waiting in the agent's inbox. `pending_messages` is
  # `Inbox.serialize/1`, so this is the same value the UI shows — the notice is
  # visible to the operator as well as queued for the model.
  # The notice is *appended*, not queued: the machine's `:workspace_notice` step
  # runs `append_many` for the pair, so it lands in the transcript (and the DB)
  # without costing a turn. Reading the transcript is what pins that.
  defp notices(pid) do
    pid
    |> state()
    |> Map.fetch!(:chat_state)
    |> Map.fetch!(:messages)
    |> Enum.map(fn {_role, message} -> text_of(message) end)
    |> Enum.filter(&(&1 =~ "[nest notice]"))
  end

  defp text_of(%{parts: parts}) do
    Enum.map_join(parts, "", fn
      %{text: text} when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp network_access(pid), do: Mounts.network_access(state(pid).mounts)

  # The mounts are not in `get_public_info/1`, and the `:space_changed` cast
  # emits no frame of its own, so the value the tools were rebuilt from is only in
  # the state. Reading it also drains the cast, which is what orders the
  # assertions above rather than racing them.
  #
  # allowlist: barrier — the mounts have no accessor and the cast broadcasts nothing
  defp state(pid), do: :sys.get_state(pid)
end

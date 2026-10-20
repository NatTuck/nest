defmodule Nest.Agents.Agent.NetworkAccessNoticeTest do
  @moduledoc """
  A live `network_access` flip tells the agent what its value now is.

  The other half of the change — the mounts moving and the tool closures being
  rebuilt from them — belongs to `Nest.Agents.Agent.SpaceNetworkAccessTest`. What
  is left here is that the *value* travels: an edit that changed only the network
  reaches the agent's notice as the new value rather than the default the agent
  started with, which no other file pins (`Nest.Agents.Agent.WorkspaceTest`
  drives the same edit → cast → append path with a workspace change instead).

  The notice exists because the system prompt's network sentence was composed
  from the value the agent started with and is deliberately never rebuilt: once a
  conversation is active the system message does not change except on compaction
  or a user-initiated model change, and a "fix" that re-rendered the sentence
  would destroy prefix caching. The prompt's own bytes surviving an environment
  edit are pinned in `Nest.Agents.Agent.WorkspaceTest` and
  `Nest.Agents.Agent.SystemPromptCacheTest`.

  The notice is *appended*, not queued: a queued notice would need a turn to
  deliver it, so a space-wide edit would cost one LLM call per live agent. The
  pair goes in as a `:workspace_notice` step, which costs no turn.

  On a `none` space the notice must not claim a sandbox the space does not have,
  because `none` runs the bare command on the host: a "disabled" flip restricts
  nothing, and a notice that said otherwise would contradict the prompt.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Spaces

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    :ok
  end

  test "a live flip tells the agent the value the edit wrote" do
    {pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    assert {:ok, _space} = Spaces.update_environment(space_id, %{network_access: false})

    # The transcript, with no turn run: `Spaces.environment_values/1` and the
    # cast's own field map are the two places that could quietly hand the agent
    # the value it started with instead of the one just written.
    assert [notice] = notices(pid)
    assert notice =~ "Network access: disabled"
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
    assert notice =~ "not enforced on this backend"
  end

  # The runtime notices in the agent's transcript — the same value the UI shows,
  # so the notice is visible to the operator as well as to the model.
  # The notice is *appended*, not queued: the machine's `:workspace_notice` step
  # runs `append_many` for the pair, so it lands in the transcript (and the DB)
  # without costing a turn. Reading the transcript is what pins that.
  #
  # `get_messages/2` is a call, so it is also what orders these assertions after
  # the `:space_changed` cast, which broadcasts nothing to wait on.
  defp notices(pid) do
    pid
    |> Agent.get_messages(1_000)
    |> Enum.map(fn {_role, message} -> text_of(message) end)
    |> Enum.filter(&(&1 =~ "[From nest runtime"))
  end

  defp text_of(%{parts: parts}) do
    Enum.map_join(parts, "", fn
      %{text: text} when is_binary(text) -> text
      _other -> ""
    end)
  end
end

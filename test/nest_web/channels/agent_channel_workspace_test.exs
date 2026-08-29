defmodule NestWeb.AgentChannelWorkspaceTest do
  @moduledoc """
  AgentChannel init payload fields for workspace editing: the `vocation`
  must carry its `modes` (so the frontend can resolve `requires_workspace`)
  and the `workspace_path` must be present so the Edit agent dialog can
  prefill + Reset the working-directory field.
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  describe "init payload workspace fields" do
    test "includes the vocation with its modes", %{socket: _socket} do
      assert_push "init", payload
      # `get_vocation_info/1` now carries `modes` so the frontend can
      # resolve `requires_workspace` from the agent channel init.
      assert is_map(payload["vocation"])
      assert Map.has_key?(payload["vocation"], "modes")
    end

    test "carries the agent workspace_path", %{user: user} do
      {_pid, agent_name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
          workspace_path: "/tmp/agent-ws",
          created_by_user_id: user.id
        })

      space_id = AgentTestHelpers.current_space_id()
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => Process.get(:agent_test_token)})

      {:ok, _, _socket} =
        subscribe_and_join(
          connected,
          NestWeb.AgentChannel,
          "agent:#{space_id}:#{agent_name}"
        )

      # Consume the setup agent's `init` first (that agent has no
      # workspace), then assert our new agent's.
      assert_push "init", _setup_init, 2000
      assert_push "init", payload
      assert payload["workspace_path"] == "/tmp/agent-ws"
    end
  end
end

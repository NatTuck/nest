defmodule NestWeb.AgentChannelWorkspaceTest do
  @moduledoc """
  AgentChannel init payload fields for workspace editing: the `vocation`
  must carry the agent's role (its id, name and slug) and the `workspace_path`
  must be present so the Edit agent dialog can prefill + Reset the
  working-directory field.

  The vocation carries no `modes` any more: the modes are universal code
  constants (`Nest.Modes`), so there is nothing per-vocation for the frontend to
  read — `vocationRequiresWorkspace/1` is a constant on the client for the same
  reason, and the modes the selector offers come from the agent's own `modes`.
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  import Nest.Test.TmpCleanup

  alias Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  describe "init payload workspace fields" do
    test "carries the vocation's identity", %{socket: _socket} do
      assert_push "init", payload
      # `get_vocation_info/1` carries the role the agent was created with, which
      # is what the header shows. It carries no `modes`: there is nothing
      # per-vocation left to describe.
      assert %{"id" => id, "name" => name, "slug" => slug} = payload["vocation"]
      assert is_integer(id)
      assert is_binary(name)
      assert is_binary(slug)
      refute Map.has_key?(payload["vocation"], "modes")
    end

    test "carries the agent workspace_path", %{user: user} do
      workspace =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "agent-ws-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(workspace)
      on_exit(fn -> rm_tmp!(workspace, "agent-ws-") end)

      {_pid, agent_name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
          workspace_path: workspace,
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
      assert_push "init", _setup_init, 1_000
      assert_push "init", payload
      assert payload["workspace_path"] == workspace
    end
  end
end

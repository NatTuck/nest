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

  setup :verify_on_exit!

  test "the init payload carries the vocation's identity and the workspace_path", %{
    space_id: space_id
  } do
    assert_push "init", payload

    # `get_vocation_info/1` carries the role the agent was created with, which
    # is what the header shows. It carries no `modes`: there is nothing
    # per-vocation left to describe.
    assert %{"id" => _, "name" => _, "slug" => _} = payload["vocation"]
    refute Map.has_key?(payload["vocation"], "modes")

    # An agent has no workspace of its own — the path is its space's — so the
    # payload mirrors the space row the Edit agent dialog prefills from.
    assert payload["workspace_path"] == Nest.Spaces.get_space(space_id).workspace_path
  end
end

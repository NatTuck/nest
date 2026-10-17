defmodule NestWeb.LobbyChannelTestHelpers do
  @moduledoc """
  Shared helpers for the `LobbyChannel` test files.

  A `create_space` push is the one path that builds a space and its root agent
  from client-supplied attrs, so it is the one place a test has to supply the
  space's workspace. A space requires one now
  (`Nest.Spaces.Space.create_changeset/2`), so a payload without a
  `"workspace_path"` is refused with `workspace_required` before the space row
  exists. `create_space_payload/1` fills it in; a test that means to exercise a
  bad workspace passes its own and that value wins.
  """

  alias Nest.Agents.AgentTestHelpers

  @doc """
  `payload` with `"workspace_path"` defaulted to a fresh temp directory (removed
  when the test ends). An explicit `"workspace_path"` wins, so the
  workspace-refusal tests still push the path they mean.
  """
  @spec create_space_payload(map()) :: map()
  def create_space_payload(payload) do
    Map.put_new_lazy(payload, "workspace_path", &AgentTestHelpers.default_test_workspace/0)
  end
end

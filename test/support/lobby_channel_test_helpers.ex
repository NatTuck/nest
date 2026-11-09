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

  import ExUnit.Assertions

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

  @doc """
  The `providers_updated` push whose provider names are exactly `names`, waited
  for and returned.

  `Providers.save/2` broadcasts on the process-global `"lobby"` topic, so a test
  joined to it receives every *other* joined test's save as well — and
  `assert_push` takes the first frame with that event, which may not be this
  save's. This waits for the frame that names exactly `names` and consumes the
  rest: they belong to tests running beside this one.

  Raises when no such frame arrives within `timeout`.
  """
  @spec assert_providers_updated([String.t()], non_neg_integer()) :: map()
  def assert_providers_updated(names, timeout \\ 1_000) do
    await_providers_updated(Enum.sort(names), System.monotonic_time(:millisecond) + timeout)
  end

  defp await_providers_updated(names, deadline) do
    receive do
      %Phoenix.Socket.Message{
        event: "providers_updated",
        payload: %{providers: providers} = payload
      } ->
        if providers |> Enum.map(& &1["name"]) |> Enum.sort() == names,
          do: payload,
          else: await_providers_updated(names, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("no providers_updated push naming #{inspect(names)} arrived in time")
    end
  end
end

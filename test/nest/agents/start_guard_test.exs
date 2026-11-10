defmodule Nest.Agents.StartGuardTest do
  @moduledoc """
  The last step of every start: a start whose space has been archived since it
  began is refused, and its process is stopped synchronously so the refusal is
  true when it is returned.

  The archived refusal end to end is `Nest.SpacesTest`'s ("an archived space's
  agent is not started on demand"). What is pinned here is the guard's own
  contract — the results it must not touch, and both arms of the termination.
  """

  use Nest.DataCase, async: true

  alias Nest.Accounts
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.StartGuard

  @model %{name: "qwen3.5-plus", provider: "model-studio"}

  setup do
    {:ok, user, _role} =
      Accounts.create_user(
        %{
          username: "start-guard-#{System.unique_integer([:positive])}",
          password: "password123"
        },
        "first-user"
      )

    {:ok, space_id} = AgentTestHelpers.create_test_space(%{}, user.id)
    {:ok, space_id: space_id}
  end

  test "a result that is not a start passes through untouched", %{space_id: space_id} do
    # The guard is the last step of every start, including the ones that already
    # failed, so it must not rewrite a caller's own refusal as an archived one.
    assert StartGuard.verify({:error, :not_found}, space_id, "anyone") ==
             {:error, :not_found}

    assert StartGuard.verify({:error, :duplicate_name}, space_id, "anyone") ==
             {:error, :duplicate_name}
  end

  test "terminating stops a live agent, and a name with no process is nothing to do", %{
    space_id: space_id
  } do
    name = "guard-agent-#{System.unique_integer([:positive])}"

    assert {:ok, ^name} =
             Agents.create_agent(space_id, @model,
               name: name,
               vocation_id: AgentTestHelpers.vocation_id_for_test()
             )

    assert {:ok, pid} = Agents.Registry.lookup(space_id, name)
    ref = Process.monitor(pid)

    assert :ok = StartGuard.terminate_child(space_id, name)

    # Synchronous, and that is the point: the name is free when this returns,
    # which is what lets a refusal answer "there is no agent" truthfully.
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    assert Agents.Registry.lookup(space_id, name) == {:error, :not_found}

    # Already gone: nothing to terminate, and still `:ok`.
    assert :ok = StartGuard.terminate_child(space_id, name)
  end
end

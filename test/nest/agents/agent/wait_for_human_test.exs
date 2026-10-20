defmodule Nest.Agents.Agent.WaitForHumanTest do
  @moduledoc """
  `agents-wait` on a **human** (`Nest.Agents.Agent.Watch.register_call/2`).

  A human is never mid-turn, so there is nothing to wait for and nothing to time
  out: the honest answer is `:ok`, and an error would teach the model that the
  address is wrong. The two things that must not happen are the ones these tests
  pin: a call that named only a human must not become "wait for every other
  agent in the space", and a call that named nobody at all must still say so.
  """

  use Nest.DataCase, async: true

  alias Nest.AddressTestHelpers
  alias Nest.Agents.Agent.Watch
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.ToolCall
  alias Nest.Persistence

  test "a call that named only a human answers inline, and watches nobody" do
    # The empty list after the human is dropped is *not* `WaitForIdle`'s "every
    # other agent in the space" form: the call named somebody, and the answer is
    # about them. A space with an agent in it is what makes that distinction
    # visible — a fall-through would have reported that agent instead.
    space = AddressTestHelpers.space_with_human("alice")
    insert_agent(space.id, "bob")

    assert {:ok, content} = register(space.id, %{"names" => ["@alice"]})

    assert content ==
             "A human is never mid-turn, so there is nothing to wait for: @alice."
  end

  test "a human mixed into a wait is dropped and named, and the agents are watched" do
    # The human is not silently swallowed: the confirmation says what was not
    # waited for, and the agents are still reported on.
    space = AddressTestHelpers.space_with_human("alice")
    insert_agent(space.id, "bob")

    assert {:ok, content} = register(space.id, %{"names" => ["@alice", "bob"]})

    assert content =~ "All agents are already idle: bob."
    assert content =~ "A human is never mid-turn, so there is nothing to wait for: @alice."
  end

  test "an address that names no user is refused, not silently dropped" do
    space = AddressTestHelpers.space_with_human("alice")

    assert {:error, "No human @nobody."} = register(space.id, %{"names" => ["@nobody"]})
  end

  # The watch machinery is never reached by these calls — they are answered
  # inline — so the context needs no live agent: `agent_pid` is only touched by
  # the path that registers a watch.
  defp register(space_id, arguments) do
    ctx = %{space_id: space_id, agent_name: "caller", agent_pid: self()}
    tc = %ToolCall{id: "wait-1", name: "agents-wait", arguments: arguments}

    Watch.register_call(ctx, tc)
  end

  # A persisted-only agent row: the listing merges persisted rows, and a wait
  # reports a persisted-only agent as `:idle` without starting it.
  defp insert_agent(space_id, name) do
    {:ok, _row} =
      Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: %{name: "test-model", provider: "test"},
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      })
  end
end

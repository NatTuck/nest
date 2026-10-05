defmodule Machine.ChildrenTest do
  @moduledoc false
  # NOTE: behavior contract carried by the tests + inline # comments.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine.Children

  test "a spawned child is running and can be listed" do
    {:ok, actions, m} = Children.spawn(Children.new(), "kid", make_ref())

    assert Children.status(m, "kid") == :running
    assert Children.running?(m, "kid")
    assert Children.running_names(m) == ["kid"]
    assert Enum.any?(actions, &match?({:track_child, "kid", _}, &1))
  end

  test "a duplicate spawn is ignored" do
    {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil)

    assert {:ignore, :duplicate_child, ^m} = Children.spawn(m, "kid", nil)
  end

  test "completion is terminal, notifies the worker, and merges usage" do
    {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil)

    {:ok, actions, m} = Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})

    assert Children.status(m, "kid") == :completed
    assert Children.running_names(m) == []
    assert Enum.any?(actions, &match?({:notify_worker, "kid", {:ok, "resp"}}, &1))
    assert Enum.any?(actions, &match?({:merge_usage, "kid", _}, &1))
  end

  test "failure and termination notify the worker with an error" do
    for {event, expected} <- [
          {{:failed, "kid", :crashed}, {:error, :crashed}},
          {{:terminated, "kid", :killed}, {:error, :killed}}
        ] do
      {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil)
      {:ok, actions, m} = Children.step(m, event)

      assert Enum.any?(actions, &match?({:notify_worker, "kid", ^expected}, &1))
      assert Children.status(m, "kid") == elem(event, 0)
    end
  end

  test "abandoning a child stops it and is terminal" do
    {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil)

    {:ok, actions, m} = Children.step(m, {:abandoned, "kid"})
    assert Enum.any?(actions, &match?({:stop_child, "kid"}, &1))
    assert Children.status(m, "kid") == :abandoned
  end

  test "an archived child emits exactly one archive action on completion" do
    {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil, true)

    {:ok, actions, m} = Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})

    assert Enum.count(actions, &match?({:archive_child, "kid"}, &1)) == 1

    # A later event (e.g. a duplicate completion) does not archive again.
    assert {:ignore, :already_terminal, _m} =
             Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})
  end

  test "a failed, terminated, or abandoned child is never archived" do
    # intentional: archiving is completion-only. A child spawned with
    # `archive: true` that fails/dies/abandons is left in place; only a
    # clean completion emits the archive action.
    for event <- [
          {:failed, "kid", :crashed},
          {:terminated, "kid", :killed},
          {:abandoned, "kid"}
        ] do
      {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil, true)
      {:ok, actions, _m} = Children.step(m, event)

      refute Enum.any?(actions, &match?({:archive_child, _}, &1))
    end
  end

  test "exactly one terminal transition wins; a later event is a no-op" do
    # intentional: a completion racing a stop cannot double-notify the
    # worker or double-count usage. The first terminal event wins; later
    # ones are ignored.
    {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil)
    {:ok, _actions, m} = Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})

    assert {:ignore, :already_terminal, ^m} =
             Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})

    assert {:ignore, :already_terminal, ^m} = Children.step(m, {:abandoned, "kid"})
  end

  test "an event for an unknown child is ignored" do
    m = Children.new()
    assert {:ignore, :unknown_child, ^m} = Children.step(m, {:completed, "ghost", "r", %{}})
    assert Children.status(m, "ghost") == :unknown
  end

  test "an unrecognized event is not applicable" do
    m = Children.new()
    assert {:ignore, :not_applicable, ^m} = Children.step(m, {:nonsense, "kid"})
  end

  test "an abandoned child that later completes does not merge usage" do
    # intentional: once the parent abandons a child (e.g. Stop), a late
    # completion does NOT count its usage. The user asked to stop
    # everything. Do not "fix" this by merging.
    {:ok, _actions, m} = Children.spawn(Children.new(), "kid", nil)
    {:ok, _actions, m} = Children.step(m, {:abandoned, "kid"})

    assert {:ignore, :already_terminal, _m} =
             Children.step(m, {:completed, "kid", "r", %{total_tokens: 7}})
  end
end

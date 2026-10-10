defmodule Machine.ChildrenTest do
  @moduledoc false
  # NOTE: behavior contract carried by the tests + inline # comments.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine.Children

  test "a registered child is running and can be listed" do
    {:ok, actions, m} = Children.register(Children.new(), "kid")

    assert actions == []
    assert Children.status(m, "kid") == :running
    assert Children.running?(m, "kid")
    assert Children.running_names(m) == ["kid"]

    # The entry holds no caller pid: the outcome is delivered into the parent's
    # own inbox by the executor, so a worker that is already gone cannot lose it.
    assert %{state: :running, result: nil, usage: nil, archive: false, target: nil} =
             m.children["kid"]
  end

  test "a child can report to a target, and the terminal transition keeps it" do
    # intentional: a batch child reports to its coordinator, so the parent reads
    # the batch's aggregate once instead of every child's answer as well. The
    # target rides on the entry (not on the action) so the action vocabulary is
    # unchanged, and the terminal transition keeps it so the executor can still
    # find it when the outcome is delivered.
    target = self()
    stranger = spawn(fn -> :ok end)

    {:ok, [], m} = Children.register(Children.new(), "kid", true, target)

    assert Children.target(m, "kid") == target
    assert Children.reporting_target?(m, target)
    refute Children.reporting_target?(m, stranger)
    refute Children.reporting_target?(m, nil)

    {:ok, actions, m} = Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})

    assert Children.target(m, "kid") == target
    assert Enum.any?(actions, &match?({:child_message, "kid", {:ok, "resp"}}, &1))
  end

  test "a duplicate register is ignored" do
    {:ok, _actions, m} = Children.register(Children.new(), "kid")

    assert {:ignore, :duplicate_child, ^m} = Children.register(m, "kid")
  end

  test "completion is terminal, delivers the answer, and merges usage" do
    {:ok, _actions, m} = Children.register(Children.new(), "kid")

    {:ok, actions, m} = Children.step(m, {:completed, "kid", "resp", %{total_tokens: 7}})

    assert Children.status(m, "kid") == :completed
    assert Children.running_names(m) == []
    assert Enum.any?(actions, &match?({:child_message, "kid", {:ok, "resp"}}, &1))
    assert Enum.any?(actions, &match?({:merge_usage, "kid", _}, &1))
  end

  test "failure and termination deliver the bad news to the parent" do
    for {event, expected} <- [
          {{:failed, "kid", :crashed}, {:failed, :crashed}},
          {{:terminated, "kid", :killed}, {:terminated, :killed}}
        ] do
      {:ok, _actions, m} = Children.register(Children.new(), "kid")
      {:ok, actions, m} = Children.step(m, event)

      assert Enum.any?(actions, &match?({:child_message, "kid", ^expected}, &1))
      assert Children.status(m, "kid") == elem(event, 0)
    end
  end

  test "abandoning a child stops it and is terminal" do
    {:ok, _actions, m} = Children.register(Children.new(), "kid")

    {:ok, actions, m} = Children.step(m, {:abandoned, "kid"})
    assert Enum.any?(actions, &match?({:stop_child, "kid"}, &1))
    assert Children.status(m, "kid") == :abandoned
  end

  test "an abandoned child gets no message, while a child that dies on its own does" do
    # intentional: the parent's own tool asked for the abandonment (a batch
    # per-item deadline, or the parent's Stop) and reports that slot itself, so
    # the runtime says nothing — a notice would tell the parent what it just
    # did. A child that dies on its own is the case the parent did *not* ask
    # for, and that one is news: `{:terminated, …}` becomes a message.
    {:ok, _actions, m} = Children.register(Children.new(), "kid")
    {:ok, actions, _m} = Children.step(m, {:abandoned, "kid"})
    assert actions == [{:stop_child, "kid"}]

    {:ok, _actions, dying} = Children.register(Children.new(), "kid")
    {:ok, dying_actions, _dying} = Children.step(dying, {:terminated, "kid", :shutdown})
    assert dying_actions == [{:child_message, "kid", {:terminated, :shutdown}}]
  end

  test "an archived child emits exactly one archive action on completion" do
    {:ok, _actions, m} = Children.register(Children.new(), "kid", true)

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
      {:ok, _actions, m} = Children.register(Children.new(), "kid", true)
      {:ok, actions, _m} = Children.step(m, event)

      refute Enum.any?(actions, &match?({:archive_child, _}, &1))
    end
  end

  test "exactly one terminal transition wins; a later event is a no-op" do
    # intentional: a completion racing a stop cannot deliver twice or
    # double-count usage. The first terminal event wins; later ones are
    # ignored.
    {:ok, _actions, m} = Children.register(Children.new(), "kid")
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
    {:ok, _actions, m} = Children.register(Children.new(), "kid")
    {:ok, _actions, m} = Children.step(m, {:abandoned, "kid"})

    assert {:ignore, :already_terminal, _m} =
             Children.step(m, {:completed, "kid", "r", %{total_tokens: 7}})
  end
end

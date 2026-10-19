defmodule Nest.Agents.Agent.PaneTest do
  @moduledoc """
  The pane manager (issues #119/#120): the per-space decision queue and the
  per-agent TODO lists.

  The manager is process-global, so every test takes its own space id — the
  state is the space's, and a fresh id is the isolation boundary. Nothing here
  touches the database.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Pane

  defp space_id, do: System.unique_integer([:positive])

  defp ask(space_id, title \\ "Which database?", asked_by \\ "agent-a") do
    Pane.ask(space_id, asked_by, title, "The tradeoffs are ...", ["Postgres", "SQLite"])
  end

  test "appends decisions and marks them obsolete in place" do
    space = space_id()
    assert {:ok, "d1"} = ask(space, "First?")
    assert {:ok, "d2"} = ask(space, "Second?")

    assert [%{id: "d1"}, %{id: "d2"}] = Pane.decisions(space)

    assert :ok = Pane.mark_obsolete(space, "d1", "I answered it myself", "agent-a")

    # Marking never removes and never reorders: `d1` is still first and `d2` is
    # untouched. That is the pane's UI rule on the server side.
    assert [%{id: "d1"} = first, %{id: "d2"} = second] = Pane.decisions(space)
    assert first.obsolete?
    assert first.obsolete_reason == "I answered it myself"
    refute second.obsolete?

    # A new question is appended at the end, never inserted above one the user
    # has already seen.
    assert {:ok, "d3"} = ask(space, "Third?")
    assert ["d1", "d2", "d3"] = Enum.map(Pane.decisions(space), & &1.id)

    assert {:error, :not_found} = Pane.mark_obsolete(space, "d99", "nothing there", "agent-a")
  end

  test "marks a decision orphaned in place, once" do
    space = space_id()
    assert {:ok, "d1"} = ask(space, "One")
    assert {:ok, "d2"} = ask(space, "Two")

    assert :ok = Pane.mark_orphaned(space, ["d1"], "the agent that asked it is gone")

    assert [%{id: "d1"} = first, %{id: "d2"}] = Pane.decisions(space)
    assert first.orphaned?
    assert first.orphaned_reason == "the agent that asked it is gone"
    assert ["d1", "d2"] = Enum.map(Pane.decisions(space), & &1.id)

    # A second mark keeps the first reason: it is the one the user was shown
    # when the question became drop-only.
    assert :ok = Pane.mark_orphaned(space, ["d1"], "a different reason")
    assert hd(Pane.decisions(space)).orphaned_reason == "the agent that asked it is gone"
  end

  test "take removes only the named decisions and returns them in queue order" do
    space = space_id()
    assert {:ok, "d1"} = ask(space, "One")
    assert {:ok, "d2"} = ask(space, "Two")
    assert {:ok, "d3"} = ask(space, "Three")

    assert ["d1", "d3"] = Enum.map(Pane.take(space, ["d1", "d99", "d3"]), & &1.id)
    assert ["d2"] = Enum.map(Pane.decisions(space), & &1.id)

    # A take that removes nothing changes nothing.
    assert Pane.take(space, ["d99"]) == []
    assert ["d2"] = Enum.map(Pane.decisions(space), & &1.id)
  end

  test "replaces one agent's TODO list and leaves another agent's alone" do
    space = space_id()

    assert :ok =
             Pane.write_todos(space, "agent-a", [%{"text" => "read", "status" => "pending"}])

    assert :ok =
             Pane.write_todos(space, "agent-b", [%{"text" => "write", "status" => "in_progress"}])

    assert :ok =
             Pane.write_todos(space, "agent-a", [
               %{"text" => "read", "status" => "done"},
               %{"text" => "ship", "status" => "pending"}
             ])

    assert [%{text: "read", status: "done"}, %{text: "ship", status: "pending"}] =
             Pane.todos(space, "agent-a")

    assert [%{text: "write", status: "in_progress"}] = Pane.todos(space, "agent-b")
    assert Pane.todos(space, "agent-c") == []
  end

  test "keeps spaces apart" do
    one = space_id()
    two = space_id()

    assert {:ok, _id} = ask(one, "Only in one")

    assert :ok =
             Pane.write_todos(one, "agent-a", [%{"text" => "a", "status" => "pending"}])

    assert Pane.decisions(two) == []
    assert Pane.todos(two, "agent-a") == []
    assert Pane.payload(two, "agent-a")["decisions"] == []
  end

  test "the payload is the wire shape, with every key present" do
    space = space_id()
    assert {:ok, "d1"} = Pane.ask(space, "agent-a", "Title", "Body", ["x", "y"])

    assert :ok =
             Pane.write_todos(space, "agent-a", [%{"text" => "step", "status" => "in_progress"}])

    # Another agent's list exists in the space, and must not be in this frame:
    # the frame is built for one viewer, because the TODO cap is per agent.
    assert :ok =
             Pane.write_todos(space, "agent-b", [%{"text" => "theirs", "status" => "pending"}])

    assert %{
             "spaceId" => ^space,
             "seq" => 3,
             "decisions" => [
               %{
                 "id" => "d1",
                 "title" => "Title",
                 "body" => "Body",
                 "options" => ["x", "y"],
                 "askedBy" => "agent-a",
                 "obsolete" => false,
                 "obsoleteReason" => nil,
                 "orphaned" => false,
                 "orphanedReason" => nil
               }
             ],
             "todos" => %{"agent-a" => [%{"text" => "step", "status" => "in_progress"}]}
           } = Pane.payload(space, "agent-a")

    # The same space, seen from agent-b's page: its own list, and only it.
    assert %{"todos" => %{"agent-b" => [%{"text" => "theirs", "status" => "pending"}]}} =
             Pane.payload(space, "agent-b")

    # An agent with no list still gets its key, so the client always reads one
    # shape.
    assert Pane.payload(space, "agent-c")["todos"] == %{"agent-c" => []}
  end

  test "increments seq on every broadcast, and a sync does not advance it" do
    space = space_id()
    :ok = Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.pane_topic(space))

    # The broadcast is a change notification, not a payload: each subscriber
    # asks for the frame built for its own agent.
    assert {:ok, id} = ask(space)
    assert_receive {:pane_changed, ^space}
    assert %{"seq" => 1, "decisions" => [%{"id" => ^id}]} = Pane.payload(space, "agent-a")

    assert :ok =
             Pane.write_todos(space, "agent-a", [%{"text" => "a", "status" => "pending"}])

    assert_receive {:pane_changed, ^space}

    # A sync is not a mutation: it reports the frame the client is on and sends
    # nothing, so it can never make a real frame look stale.
    assert Pane.payload(space, "agent-a")["seq"] == 2
    refute_received {:pane_changed, _}
  end

  test "refuses to obsolete another agent's question" do
    space = space_id()
    assert {:ok, "d1"} = ask(space, "One", "agent-a")

    assert {:error, :not_yours} = Pane.mark_obsolete(space, "d1", "not mine", "agent-b")

    # Nothing was marked, and the question is untouched.
    assert [%{id: "d1", obsolete?: false}] = Pane.decisions(space)

    assert :ok = Pane.mark_obsolete(space, "d1", "mine after all", "agent-a")
    assert [%{id: "d1", obsolete?: true}] = Pane.decisions(space)
  end

  test "caps the decision queue" do
    space = space_id()

    for n <- 1..50 do
      assert {:ok, _id} = ask(space, "Question #{n}")
    end

    assert {:error, message} = ask(space, "One too many")
    assert message =~ "full"
    assert length(Pane.decisions(space)) == 50
  end

  test "validates everything an agent can send" do
    space = space_id()
    assert {:ok, id} = ask(space)

    assert {:error, message} =
             Pane.ask(space, "a", String.duplicate("x", 201), "body", ["a", "b"])

    assert message =~ "title"

    assert {:error, message} = Pane.ask(space, "a", "T", "", ["a", "b"])
    assert message =~ "body"

    assert {:error, message} = Pane.ask(space, "a", 42, "B", ["a", "b"])
    assert message =~ "must be a string"

    assert {:error, message} = Pane.ask(space, "a", "T", "B", ["only one"])
    assert message =~ "Options"

    assert {:error, message} = Pane.ask(space, "a", "T", "B", ~w(a b c d e f))
    assert message =~ "Options"

    assert {:error, message} =
             Pane.write_todos(space, "a", [%{"text" => "x", "status" => "later"}])

    assert message =~ "Unknown TODO status"

    assert {:error, message} = Pane.write_todos(space, "a", [%{"status" => "pending"}])
    assert message =~ "text string"

    too_many = for n <- 1..51, do: %{"text" => "step #{n}", "status" => "pending"}
    assert {:error, message} = Pane.write_todos(space, "a", too_many)
    assert message =~ "at most"

    assert {:error, message} = Pane.mark_obsolete(space, id, "", "agent-a")
    assert message =~ "reason"

    # Nothing a refused call carried was written.
    assert [%{id: ^id, title: "Which database?"}] = Pane.decisions(space)
    assert Pane.todos(space, "a") == []
  end
end

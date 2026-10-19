defmodule Nest.Tools.PaneTest do
  @moduledoc """
  The `pane` tool group (issues #119/#120). Each tool reads the calling agent's
  `{space_id, agent_name}` from the per-call context, exactly as the
  `shell-list`/`shell-wait`/`shell-kill` tools do, so every test here drives a
  tool through the context the `BatchSizer` supplies.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Pane
  alias Nest.Sandbox.Mounts
  alias Nest.Tools

  defp space_id, do: System.unique_integer([:positive])

  defp context(space_id, name), do: %{space_id: space_id, agent_name: name}

  defp invoke(tool, args, context) do
    Tools.get_function(tool, Mounts.new(nil, nil)).function.(args, context)
  end

  defp ask_args(title) do
    %{"title" => title, "body" => "The tradeoffs are ...", "options" => ["a", "b"]}
  end

  test "decisions-ask files a question and tells the agent not to wait" do
    space = space_id()
    agent = context(space, "agent-a")

    assert {:ok, result} = invoke("decisions-ask", ask_args("Which DB?"), agent)

    assert result =~ "d1"
    assert result =~ "do not wait"

    assert {:ok, list} = invoke("decisions-list", %{}, agent)
    assert list =~ "- d1: Which DB? (asked by agent-a)"
    refute list =~ "obsolete"
  end

  test "decisions-obsolete marks in place and never removes the question" do
    space = space_id()
    agent = context(space, "agent-a")

    assert {:ok, _} = invoke("decisions-ask", ask_args("Which DB?"), agent)

    assert {:ok, result} =
             invoke(
               "decisions-obsolete",
               %{"id" => "d1", "reason" => "Answered it myself"},
               agent
             )

    assert result =~ "d1"
    assert result =~ "stays"

    # Still listed, still first, now marked — that is what "in place" means.
    assert {:ok, list} = invoke("decisions-list", %{}, agent)
    assert list =~ "- d1: Which DB?"
    assert list =~ "[obsolete: Answered it myself]"

    # An orphaned question shows its flag too: the pane's drop-only state is
    # server state, not a client-side guess.
    assert {:ok, "d2"} = Pane.ask(space, "ghost", "Orphan?", "Body", ["a", "b"])
    assert :ok = Pane.mark_orphaned(space, ["d2"], "the agent that asked it is gone")

    assert {:ok, list} = invoke("decisions-list", %{}, agent)
    assert list =~ "- d2: Orphan? (asked by ghost) [orphaned: the agent that asked it is gone]"

    assert {:error, message} =
             invoke("decisions-obsolete", %{"id" => "d99", "reason" => "gone"}, agent)

    assert message =~ "d99"
  end

  test "todos-write replaces the caller's list and todos-list renders it" do
    space = space_id()
    agent = context(space, "agent-a")

    assert {:ok, result} =
             invoke(
               "todos-write",
               %{
                 "items" => [
                   %{"text" => "read the code", "status" => "done"},
                   %{"text" => "fix the bug", "status" => "in_progress"}
                 ]
               },
               agent
             )

    assert result =~ "2 item(s)"

    assert {:ok, list} = invoke("todos-list", %{}, agent)
    assert list == "- [done] read the code\n- [in_progress] fix the bug"

    # A second write replaces the list; there are no ids and no per-item update.
    assert {:ok, _} =
             invoke(
               "todos-write",
               %{"items" => [%{"text" => "ship it", "status" => "pending"}]},
               agent
             )

    assert {:ok, list} = invoke("todos-list", %{}, agent)
    assert list == "- [pending] ship it"
  end

  test "the tools are scoped to the calling agent and its space" do
    space = space_id()
    a = context(space, "agent-a")
    b = context(space, "agent-b")

    assert {:ok, _} =
             invoke(
               "todos-write",
               %{"items" => [%{"text" => "a step", "status" => "pending"}]},
               a
             )

    assert {:ok, "Your TODO list is empty."} = invoke("todos-list", %{}, b)

    assert {:ok, _} = invoke("decisions-ask", ask_args("B's question"), b)

    # The decision queue is the space's, so `a` sees `b`'s question — and the
    # frame names the agent the answer must go back to.
    assert {:ok, list} = invoke("decisions-list", %{}, a)
    assert list =~ "- d1: B's question (asked by agent-b)"

    # A different space sees neither.
    other = context(space_id(), "agent-a")
    assert {:ok, "No open decisions."} = invoke("decisions-list", %{}, other)
  end

  test "refuses invalid input with a message the model can act on" do
    space = space_id()
    agent = context(space, "agent-a")

    assert {:error, message} =
             invoke(
               "decisions-ask",
               %{"title" => "T", "body" => "B", "options" => ["one"]},
               agent
             )

    assert message =~ "Options"

    assert {:error, message} =
             invoke(
               "todos-write",
               %{"items" => [%{"text" => "x", "status" => "later"}]},
               agent
             )

    assert message =~ "status"

    assert {:error, message} = invoke("todos-write", %{"nope" => []}, agent)
    assert message =~ "items"

    # A refused call writes nothing.
    assert {:ok, "No open decisions."} = invoke("decisions-list", %{}, agent)
    assert {:ok, "Your TODO list is empty."} = invoke("todos-list", %{}, agent)
  end

  test "a call with no agent identity is refused" do
    assert {:error, message} = invoke("decisions-list", %{}, %{})
    assert message =~ "identity"

    assert {:error, message} = invoke("todos-list", %{}, %{space_id: 1})
    assert message =~ "identity"
  end

  test "the schemas state the non-blocking contract and the item vocabulary" do
    ask = Tools.get_function("decisions-ask", Mounts.new(nil, nil))
    props = ask.parameters_schema["properties"]

    assert ask.parameters_schema["required"] == ["title", "body", "options"]
    assert props["options"]["minItems"] == 2
    assert props["options"]["maxItems"] == 5
    assert ask.description =~ "NOT wait for an answer"
    assert ask.description =~ "answers later, as a message"

    todos = Tools.get_function("todos-write", Mounts.new(nil, nil))
    items = todos.parameters_schema["properties"]["items"]

    assert items["items"]["properties"]["status"]["enum"] == ~w(pending in_progress done)
    assert todos.parameters_schema["required"] == ["items"]
    assert todos.description =~ "send the whole list"
  end
end

defmodule Nest.Agents.Agent.ToolLoopArchiveTest do
  @moduledoc """
  `agents-archive` inside `ToolLoop.execute/3`.

  The tool routes through the parent GenServer, so a `FakeParent` pins its
  contract — one call per name, the confirmation, the per-name error
  surfacing — without a turn.

  `name` takes one agent name or a list of them (issue #93): cleaning up after
  a multi-agent workflow usually means several at once, and one refused name
  must not abandon the names after it.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    :ok
  end

  defmodule FakeParent do
    @moduledoc """
    Test double for the parent Agent GenServer, started under
    `Agents.Registry.via_tuple(space_id, name)` so `ToolLoop` routes to it
    through the registry.

    It answers `:archive_agent_request` with `{:ok, name}`, or with
    `{:error, :not_found}` for any name listed in `refuse`.
    """
    use GenServer

    def start(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:via])

    @impl true
    def init(opts), do: {:ok, %{refuse: Keyword.get(opts, :refuse, [])}}

    @impl true
    def handle_call({:archive_agent_request, _task_pid, name}, _from, state) do
      if name in state.refuse do
        {:reply, {:error, :not_found}, state}
      else
        {:reply, {:ok, name}, state}
      end
    end

    def handle_call(_, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_cast(_, state), do: {:noreply, state}

    @impl true
    def handle_info(_, state), do: {:noreply, state}
  end

  describe "agents-archive" do
    test "one name archives that agent" do
      {:ok, _pid} = start_parent("archive-one")

      assert [result] = archive_from("archive-one", "spare-agent")

      assert %ToolResult{
               name: "agents-archive",
               arguments: %{"name" => "spare-agent"},
               content: "Archived agent spare-agent.",
               is_error: false
             } = result
    end

    test "a list archives every name, one sentence each" do
      {:ok, _pid} = start_parent("archive-many")

      assert [result] = archive_from("archive-many", ["a1", "a2", "a3"])

      assert %ToolResult{is_error: false, content: content} = result
      assert content == "Archived agent a1.\nArchived agent a2.\nArchived agent a3."
    end

    test "one refused name does not abandon the names after it" do
      {:ok, _pid} = start_parent("archive-partial", refuse: ["gone"])

      {results, log} = with_log(fn -> archive_from("archive-partial", ["a1", "gone", "a3"]) end)

      assert [%ToolResult{is_error: true, content: content}] = results

      assert content ==
               "Archived agent a1.\nCould not archive gone: :not_found\nArchived agent a3."

      # The call did not fully succeed, so BatchSizer logs the result.
      assert log =~ "is_error=true tool result"
    end

    test "an empty list, a malformed element, and a blank name are all rejected loudly" do
      {:ok, _pid} = start_parent("archive-bad")

      # An empty list is far likelier to be a malformed call than a request to
      # archive nothing, and a non-string element must not be dropped: either
      # would leave an agent the caller asked to clean up still running. A blank
      # name is the same class — it is a typo, not an agent, and looking it up
      # would report `:not_found`, which reads as "that agent is gone".
      {results, log} = with_log(fn -> archive_from("archive-bad", []) end)

      assert [%ToolResult{is_error: true, content: empty_content}] = results

      assert empty_content == "name must be an agent name or a list of agent names; got []."

      assert log =~ "is_error=true tool result"

      {results, log} = with_log(fn -> archive_from("archive-bad", " ") end)

      assert [%ToolResult{is_error: true, content: blank_content}] = results

      assert blank_content ==
               ~s(name must be an agent name or a list of agent names; got " ".)

      assert log =~ "is_error=true tool result"

      {results, log} = with_log(fn -> archive_from("archive-bad", ["ok", 7]) end)

      assert [%ToolResult{is_error: true, content: mixed_content}] = results

      assert mixed_content ==
               ~s(name must be an agent name or a list of agent names; got ["ok", 7].)

      assert log =~ "is_error=true tool result"
    end
  end

  # -- helpers --

  defp start_parent(name, opts \\ []) do
    via = AgentsRegistry.via_tuple(AgentTestHelpers.current_space_id(), name)
    FakeParent.start(Keyword.merge([via: via], opts))
  end

  defp archive_from(parent_name, name) do
    ctx = %{
      agent_pid: self(),
      agent_name: parent_name,
      space_id: AgentTestHelpers.current_space_id(),
      context_limit: 100_000,
      messages: []
    }

    ToolLoop.execute(ctx, nil, [
      %ToolCall{id: "archive-1", name: "agents-archive", arguments: %{"name" => name}}
    ])
  end
end

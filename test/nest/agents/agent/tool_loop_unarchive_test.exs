defmodule Nest.Agents.Agent.ToolLoopUnarchiveTest do
  @moduledoc """
  `agents-unarchive` and `agents-list-archived` inside
  `ToolLoop.execute/3`.

  `agents-unarchive` routes through the parent GenServer (a
  `FakeParent` pins its contract — the confirmation, the error
  surfacing — without a turn). `agents-list-archived` is a pure
  read of the space's archived rows, tested against real
  persisted rows.
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

  describe "agents-unarchive" do
    defmodule FakeParent do
      @moduledoc """
      Test double for the parent Agent GenServer, started under
      `Agents.Registry.via_tuple(space_id, name)` so `ToolLoop`
      routes to it through the registry.

      It answers `:unarchive_agent_request` with `{:ok, name}` —
      or `{:error, reason}` when `reply_failure` is set.
      """
      use GenServer

      defstruct [:restored_name, :reply_failure]

      def start(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:via])

      @impl true
      def init(opts) do
        {:ok,
         %__MODULE__{
           restored_name: Keyword.get(opts, :restored_name, "restored-agent"),
           reply_failure: Keyword.get(opts, :reply_failure)
         }}
      end

      @impl true
      def handle_call({:unarchive_agent_request, _task_pid, _name}, _from, state) do
        case state.reply_failure do
          nil -> {:reply, {:ok, state.restored_name}, state}
          reason -> {:reply, {:error, reason}, state}
        end
      end

      def handle_call(_, _from, state), do: {:reply, :ok, state}

      @impl true
      def handle_cast(_, state), do: {:noreply, state}

      @impl true
      def handle_info(_, state), do: {:noreply, state}
    end

    test "a restore returns a confirmation naming the agent" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple(AgentTestHelpers.current_space_id(), "parent-success"),
          restored_name: "old-specialist"
        )

      assert [result] = unarchive_from("parent-success", "old-specialist")

      assert %ToolResult{
               tool_call_id: "unarchive-1",
               name: "agents-unarchive",
               arguments: %{"name" => "old-specialist"},
               content: content,
               is_error: false
             } = result

      assert content =~ "Restored agent old-specialist."
    end

    test "a parent reply of {:error, _} surfaces as an is_error ToolResult" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple(AgentTestHelpers.current_space_id(), "parent-err"),
          reply_failure: :not_found
        )

      # BatchSizer logs every `is_error` result: expected, so capture it.
      {results, log} = with_log(fn -> unarchive_from("parent-err", "ghost") end)

      assert [
               %ToolResult{
                 tool_call_id: "unarchive-1",
                 name: "agents-unarchive",
                 is_error: true,
                 content: content
               }
             ] = results

      assert content =~ "Could not restore ghost"
      assert content =~ "not_found"
      assert log =~ "is_error=true tool result"
    end
  end

  describe "agents-list-archived" do
    test "lists the space's archived agents with parent and depth" do
      space_id = AgentTestHelpers.current_space_id()
      suffix = System.unique_integer([:positive])
      parent_name = "tl-arch-parent-#{suffix}"
      child_name = "tl-arch-child-#{suffix}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}
      vid = AgentTestHelpers.vocation_id_for_test()

      {:ok, parent_row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: parent_name,
          model: model,
          vocation_id: vid
        })

      {:ok, _child_row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: child_name,
          model: model,
          vocation_id: vid,
          parent_id: parent_row.id,
          depth: 1
        })

      for name <- [parent_name, child_name] do
        assert :ok = Nest.Persistence.archive_agent(space_id, name)
      end

      # A non-archived row must not appear in the listing.
      {:ok, _active_row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: "tl-arch-active-#{suffix}",
          model: model,
          vocation_id: vid
        })

      assert [result] = list_archived_from("parent-read")

      assert %ToolResult{
               name: "agents-list-archived",
               content: content,
               is_error: false
             } = result

      assert content =~ parent_name
      assert content =~ child_name
      # The child's parent is resolved by name so the model can
      # see the subtree it is restoring.
      assert content =~ ~s(parent: "#{parent_name}")
      refute content =~ "tl-arch-active-#{suffix}"
    end

    test "an empty space reports no archived agents" do
      assert [result] = list_archived_from("parent-empty")

      assert %ToolResult{
               name: "agents-list-archived",
               content: "No archived agents in this space.",
               is_error: false
             } = result
    end
  end

  # -- helpers --

  defp ctx(agent_name) do
    %{
      agent_pid: self(),
      agent_name: agent_name,
      space_id: AgentTestHelpers.current_space_id(),
      context_limit: 100_000,
      messages: []
    }
  end

  defp unarchive_from(parent_name, target) do
    ToolLoop.execute(ctx(parent_name), nil, [
      %ToolCall{id: "unarchive-1", name: "agents-unarchive", arguments: %{"name" => target}}
    ])
  end

  defp list_archived_from(parent_name) do
    ToolLoop.execute(ctx(parent_name), nil, [
      %ToolCall{id: "list-archived-1", name: "agents-list-archived", arguments: %{}}
    ])
  end
end

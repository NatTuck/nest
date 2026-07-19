defmodule Nest.Agents.Agent.ToolLoopCloneAgentTest do
  @moduledoc """
  Tests for `clone_agent` interception inside
  `ToolLoop.execute/3`.

  The full E2E flow (driving MockClient through the
  parent's chat turn → spawn child → child completes →
  parent's tool worker unblocks) lives in the planned
  `clone_agent_flow_test.exs`. This module exercises the
  interception narrowly:

    * `clone_agent` tool calls route through the
      synchronous parent-via-tuple path.
    * The parent's `{:error, _}` reply surfaces as an
      `is_error` ToolResult rather than crashing the
      worker.

  Mixed-batch reordering is exercised separately by the
  BatchSizer + tool ordering test in `batch_sizer_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Messages.{ToolCall, ToolResult}

  defmodule FakeParent do
    @moduledoc """
    Test double for the parent Agent GenServer. Started
    under `Agents.Registry.via_tuple(name)` so
    `ToolLoop.run_clone_agent/2` can route to it through
    the agents registry (no pid lookup).

    Behavior:

      * `:clone_agent_request` synchronously replies
        `{:ok, child_name}` then sends the matching
        `:clone_agent_result` to the calling worker (we
        use the `from` arg to recover the worker's pid).
      * `:clone_agent_request` opts can override the
        response: `{:reply_failure, reason}` makes the
        parent reply with `{:error, reason}` (no result
        sent).
    """
    use GenServer

    defstruct [:child_name, :response, :reply_failure]

    def start(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:via])
    end

    @impl true
    def init(opts) do
      state = %__MODULE__{
        child_name: Keyword.get(opts, :child_name, "test-child"),
        response: Keyword.get(opts, :response, "child done"),
        reply_failure: Keyword.get(opts, :reply_failure)
      }

      {:ok, state}
    end

    @impl true
    def handle_call({:clone_agent_request, _task_pid, _instruction}, {worker_pid, _tag}, state) do
      case state.reply_failure do
        nil ->
          send(worker_pid, {:clone_agent_result, state.child_name, state.response})
          {:reply, {:ok, state.child_name}, state}

        reason ->
          {:reply, {:error, reason}, state}
      end
    end

    def handle_call(_, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_cast(_, state), do: {:noreply, state}

    @impl true
    def handle_info(_, state), do: {:noreply, state}
  end

  describe "clone_agent routing" do
    test "a single clone_agent call produces a synthetic ToolResult with the child's response" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple("parent-success"),
          child_name: "child-success",
          response: "delegate said hello"
        )

      results =
        ToolLoop.execute(
          %{agent_name: "parent-success"},
          %{},
          [
            %ToolCall{
              id: "call-1",
              name: "clone_agent",
              arguments: %{"instruction" => "say hi"}
            }
          ]
        )

      assert [
               %ToolResult{
                 tool_call_id: "call-1",
                 name: "clone_agent",
                 arguments: %{"instruction" => "say hi"},
                 content: "delegate said hello",
                 is_error: false
               }
             ] = results
    end

    test "parent reply of {:error, _} surfaces as an is_error ToolResult" do
      {:ok, _pid} =
        FakeParent.start(
          via: AgentsRegistry.via_tuple("parent-err"),
          reply_failure: :max_depth_reached
        )

      results =
        ToolLoop.execute(
          %{agent_name: "parent-err"},
          %{},
          [
            %ToolCall{
              id: "call-1",
              name: "clone_agent",
              arguments: %{"instruction" => "x"}
            }
          ]
        )

      assert [%ToolResult{tool_call_id: "call-1", name: "clone_agent", is_error: true}] = results
      assert results |> hd() |> Map.get(:content) =~ "max_depth_reached"
    end
  end
end

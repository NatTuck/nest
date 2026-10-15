defmodule Nest.TestSupport.ExecutorTestHelpers do
  @moduledoc """
  The session fixtures `Nest.Agents.Agent.Turn.ExecutorTest` drives executor
  actions with.

  Extracted to make room under the 700-line cap, which that file went over once
  the capture fixes added the comments explaining themselves — issue #80's
  remedy, the same one `Nest.TestSupport.MachineTestHelpers` applies — and
  because `ctx/0` is the piece that is genuinely fiddly to rebuild.

  ## The row

  `state/0` owns a real `agents` row. These tests drive executor actions, not
  persistence, so the row is the smallest one that makes an append succeed:
  `append_message/3` resolves the name and refuses when it matches no row,
  logging `Failed to persist message ... :agent_not_found` for every append.
  Without the row the fixture's own state was the source of console output, so
  every test that drove an append had to hide it behind a `capture_log` — and a
  `capture_log` captures whole-VM output, which is why the leak was intermittent
  and why two tests that asserted the warning were racing every concurrent
  capture for the line they asserted on.

  `chat_state.agent_row_id` is set to the row's id on purpose: the append path
  passes it as `expect_agent_row_id`, and an explicit `nil` there means "this
  session has no row", so leaving it nil would trade the `:agent_not_found`
  warning for an `:agent_row_reused` one.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Persistence

  @doc "A hand-built session that owns a real `agents` row."
  def state do
    name = "exec-#{System.unique_integer([:positive])}"
    space_id = test_space_id()
    {:ok, row} = Persistence.insert_agent(agent_attrs(name))

    %Agent{
      name: name,
      space_id: space_id,
      model: %{name: "m"},
      client_config: %Nest.LLM.ClientConfig{client: Nest.LLM.MockClient, model: "m"},
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      chat_state: %Agent.ChatState{agent_row_id: row.id},
      live: %Agent.ChatState.Live{
        machine: %Machine{work: %Machine.Work{ctx: ctx()}}
      },
      vocation: vocation()
    }
  end

  @doc """
  A vocation defining the modes the drain tests request, so
  `ChatPipeline.resolve_mode_and_caps/3` resolves "plan" to "plan" and an
  unknown mode to the "chat" default.
  """
  def vocation do
    %Nest.Vocations.Vocation{
      modes: %{
        "chat" => %{"caps" => %{}},
        "plan" => %{"caps" => %{}},
        "review" => %{"caps" => %{}}
      }
    }
  end

  @doc """
  A process registered as `{space_id, name}` — the parent a `{:finalize, …}`
  action reports to, so a test can assert whether it was told anything.

  `send_parent/2` casts through `Registry.via_tuple/2`, so the payload lands in
  this process's mailbox, where `parent_messages/1` reads it. Spawned rather
  than registered from the test process itself: the registry links every
  process it holds, so a test process registered there dies with the registry.
  """
  def register_parent(space_id, name) do
    test_pid = self()

    parent =
      spawn(fn ->
        {:ok, _} = Registry.register(Nest.Agents.Registry, {space_id, name}, nil)
        send(test_pid, {:parent_registered, self()})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:parent_registered, ^parent}
    on_exit(fn -> Process.exit(parent, :kill) end)
    parent
  end

  @doc "The messages `register_parent/2`'s process has been sent, oldest first."
  def parent_messages(parent) do
    {:messages, messages} = Process.info(parent, :messages)
    messages
  end

  @doc "The turn context the executor reads its world from."
  def ctx do
    %{
      agent_pid: self(),
      agent_name: "a",
      space_id: 1,
      client_config: %Nest.LLM.ClientConfig{client: Nest.LLM.MockClient, model: "m"},
      tools: [],
      tool_choice: :auto,
      caps: %{},
      context_limit: 100_000,
      context_limit_source: :default,
      messages: [],
      tmp_path: nil,
      workspace_path: nil,
      mode: "chat",
      next_message_index: 0,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end
end

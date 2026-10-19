defmodule Nest.Agents.AgentsBatchTestHelpers do
  @moduledoc """
  The harness `Nest.Agents.Agent.AgentsBatchTest` drives a parent's whole batch
  turn through: start a parent whose `Agents.chat/3` is stubbed, run the turn
  that calls `agents-batch`, and read the frames it produces.

  It lives here rather than in that test module because the module is at the
  repo's total-line cap (`Nest.Credo.Check.SourceFileMaxLines`), and the two
  fences a test needs to make an interleaving deterministic are not free:

    * `await_idle/1` waits for the `chat:status` frame the machine broadcasts
      when it settles back to `:idle`;
    * `await_message/2` waits for a delivered message *and* the turn that
      delivery started.

  `set_status/2` and `reset_to_idle/1` fabricate and undo a busy phase for a
  test that needs the parent busy at a moment the machine cannot be driven to
  (`Machine.status_to_machine/2` is the mapping the inbox tests use).
  """

  import ExUnit.Assertions
  import Nest.Agents.AgentTurnTestHelpers, only: [await_delivery: 1]

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  # The parent's queued-message count, for a test that has to know a request is
  # already in its mailbox before releasing it.
  def queued_messages(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} -> count
      _other -> 0
    end
  end

  def batch_target(parent_pid, child_name) do
    Children.target(Agent.get_children(parent_pid, 1_000), child_name)
  end

  # Start a parent agent whose `Agents.chat/3` is stubbed (children don't run a
  # real chat cycle) and allow the coordinator to call the stub.
  def start_batch_parent(vid) do
    {parent_pid, parent_name} =
      AgentTestHelpers.start_spawnable_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    Mimic.allow(Agents, self(), parent_pid)
    {parent_pid, parent_name}
  end

  # Queue a tool call as the model's first response and a final text response,
  # then kick off the parent's chat turn. (The turns the delivered messages
  # start answer with MockClient's random fallback: this test is about the
  # batch's own messages.)
  def run_batch(parent_pid, id, args) do
    # Named, not omitted: the parent's own, which the removed fallback picked.
    args =
      Map.put_new(args, "vocation", Agent.get_public_info(parent_pid, 1_000).vocation_slug)

    MockClient.set_tool_response(%{
      text: "batching",
      tool_calls: [%{id: id, name: "agents-batch", arguments: args}]
    })

    MockClient.set_response("parent final")
    :ok = Agent.chat(parent_pid, "batch a thing")
  end

  # Wait until the parent has delivered a message containing `needle` and
  # finished the turn that delivery started, so no background process touches
  # the sandbox after the test ends. Returns every matching text.
  #
  # `await_delivery/1` consumes the delivery's own frame, and the stale frames in
  # front of it; the `idle` frame that follows it is the turn's end — every status
  # broadcast carries the status the machine has *now*, so an `idle` frame after
  # the delivery means the delivery's turn has settled.
  def await_message(parent_pid, needle) do
    await_delivery(needle)
    assert_receive {:chat_status, %{status: "idle"}}, 1_000
    delivered_texts(Agent.get_messages(parent_pid, 1_000), needle)
  end

  # Wait until the parent is idle (its turn is over), so a test that pokes its
  # state cannot race the turn's own transitions. The `chat:status` frame the
  # machine emits when it settles back to `:idle` is the event that decides it
  # (`Turn.run/6` broadcasts on every status change), and
  # `AgentTestHelpers.start_agent/1` subscribes this test pid to the parent's
  # topic, so the frame is the fence; 1s is only the failure bound. Returns the
  # state, read behind the frame the agent has already broadcast. Kept as a
  # whole-state read: its callers assert on the children sub-machine *and* on
  # the transcript, and no single accessor returns both.
  #
  # It is *not* a fence for "the parent is idle right now": an `idle` frame from
  # an earlier turn can still be in the mailbox. Use `Agent.get_status/2` for
  # that — it is a call, so its answer is the agent's state at that moment.
  def await_idle(parent_pid) do
    assert_receive {:chat_status, %{status: "idle"}}, 1_000
    # allowlist: snapshot — children + messages
    :sys.get_state(parent_pid, 1_000)
  end

  # Fabricate a busy phase for a test that needs the parent busy at a moment the
  # machine cannot be driven to. `status_to_machine/2` is the test-support
  # mapping the inbox tests use.
  def set_status(pid, status) do
    replace_state(pid, fn state ->
      put_in(state.live.machine, Machine.status_to_machine(state.live.machine, status))
    end)
  end

  # Undo a fabricated busy status and the queue a test filled, so the agent is
  # idle (and empty) for the teardown.
  def reset_to_idle(pid) do
    replace_state(pid, fn state ->
      state = put_in(state.live.inbox, [])
      put_in(state.live.machine, Machine.status_to_machine(state.live.machine, :idle))
    end)
  end

  # The aggregate message, JSON-decoded: the delivered text carries the
  # delivery's `[mode: …]` prefix on its own line.
  def await_aggregate(parent_pid, needle) do
    [message] =
      await_message(parent_pid, needle)
      |> tap(fn texts ->
        assert length(texts) == 1, "expected one aggregate, got: #{inspect(texts)}"
      end)

    json = message |> String.split("\n") |> List.last()

    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, reason} -> flunk("not JSON: #{inspect(message)} (#{inspect(reason)})")
    end
  end

  def delivered_texts(messages, needle) do
    for {:user, %{parts: parts}} <- messages,
        %Part.Text{text: text} <- parts,
        text =~ needle,
        do: text
  end

  def batch_tool_result(messages) do
    {:tool, %{parts: [%Part.ToolResult{name: "agents-batch"} = result]}} =
      Enum.find(messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-batch"}, &1))

        _ ->
          false
      end)

    result
  end

  # Collect `count` `agent:created` frames for `parent_name`, in the order
  # they arrive (item order). Non-matching frames from concurrent tests are
  # filtered by the `parentName` guard. There is no synchronous point to wait on
  # here: `Agent.chat/2` only casts, and the broadcast is emitted by the parent
  # while it handles a `{:spawn_agent_request, ...}` call from the coordinator
  # task, which is itself spawned a few hops later. So the fence is a real
  # (bounded) wait, and the timeout is PER CHILD: a 3-item batch can spend up to
  # 3x this. 1s is a wide margin — the whole file runs in well under a second.
  def collect_child_names(_parent_name, 0, acc), do: Enum.reverse(acc)

  def collect_child_names(parent_name, n, acc) do
    assert_receive {:agent_created, %{"name" => name, "parentName" => ^parent_name}},
                   1_000

    collect_child_names(parent_name, n - 1, [name | acc])
  end

  def collect_child_names(parent_name, n), do: collect_child_names(parent_name, n, [])

  # #41: `agent:created` rides the per-space topic, not the shared "lobby" one.
  def space_topic do
    Broadcasts.space_topic(AgentTestHelpers.current_space_id())
  end

  # Cast a child's completion to the parent, mimicking the child's idle
  # completion in production.
  def cast_child_completed(parent_pid, child_name, response) do
    usage = %{
      Broadcasts.empty_usage_totals()
      | output_tokens: 42,
        total_tokens: 42,
        last_output: 42
    }

    GenServer.cast(parent_pid, {:child_completed, child_name, response, usage})
  end

  # `archive` defaults to true, so `handle_child_completed/4` archives each
  # child as the parent processes its completion. The DB `archived` flag is set
  # synchronously in that path, so it's a deterministic proof that archiving ran
  # (no liveness polling / DOWN waits).
  def assert_children_archived(space_id, names) do
    Enum.each(names, fn name ->
      {:ok, row} = Nest.Persistence.fetch_agent(space_id, name)
      assert row.archived == true, "child #{name} should be marked archived in the DB"
    end)
  end

  def stub_child_chat do
    Mimic.copy(Agents)
    Mimic.stub(Agents, :chat, fn _space_id, _name, _content, _mode, _sender -> :ok end)
  end

  # The coordinator's vocation exposes `agents-batch`. The children take the
  # vocation `run_batch/3` names explicitly, because `agents-batch` no longer hands
  # a child the caller's own when `vocation` is omitted (stage 4b).
  def upsert_batch_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "AgentsBatch #{System.unique_integer([:positive])}",
        description: "End-to-end agents-batch test",
        system_prompt: "Batch work over items.",
        tools: ["context", "agents"]
      })

    vid
  end

  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 1_000)
end

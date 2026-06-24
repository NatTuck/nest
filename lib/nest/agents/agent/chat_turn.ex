defmodule Nest.Agents.Agent.ChatTurn do
  @moduledoc """
  The per-turn iteration state machine. One ChatTurn per
  chat turn; lives as a `:temporary` GenServer under
  `Nest.Agents.Agent.ChatTurnSupervisor`.

  The ChatTurn drives the LLM call chain. The Agent is
  the single source of truth for `messages` — the
  ChatTurn queries via `GenServer.call(:get_messages)`
  before each iteration and appends via
  `GenServer.call({:append_message, _})` after each
  response.

  HTTP and tool workers are plain `Task`s spawned by
  the ChatTurn under `Nest.Agents.TaskSupervisor`. They
  send their results back to the ChatTurn's mailbox.
  The ChatTurn traps exits so an unexpected worker crash
  becomes a `{:chat_crashed, _, _}` to the Agent.

  ## Mailbox protocol (ChatTurn → itself)

    * `:iterate` — start the next iteration step
    * `{:http_response, response}` — the HTTP worker
      completed with a normalized `RunResponse`
    * `{:http_error, error}` — the HTTP worker errored
    * `{:worker_crashed, exception, stacktrace}` —
      the HTTP worker raised an unhandled exception
    * `{:tool_results, results}` — the tool worker
      returned a list of `ToolResult` structs
    * `{:stop_chat, from}` — the user clicked Stop
    * `{:EXIT, pid, reason}` — a worker died

  ## Agent contract (ChatTurn → Agent, `send/2`)

    * `{:delta_received, text, :text | :thinking}` —
      the Agent re-broadcasts and updates its
      streaming_acc mirror for `get_public_info`
    * `{:thinking_signature_received, sig}` — no-op
      (the ChatTurn captures the signature into the
      assistant message it builds from the response)
    * `{:llm_usage, usage}` — merge into running totals
    * `{:llm_error, error_msg}` — log + broadcast +
      transition to :idle (stream-level error)
    * `{:api_log, idx, id, payload}` — queue for
      pending api_logs at message_index `idx`
    * `{:api_log_sequences_updated, sequences}` —
      end-of-turn ack; clears chat_turn_pid + cancelled
    * `{:tool_calls_received, msg}` — append the
      assistant-with-tool-calls message and transition
      to `:executing_tools`
    * `{:tool_results_received, msg}` — append the tool
      result message and transition back to `:streaming`
    * `{:chat_idle, self()}` — end-of-turn, no-stop
    * `{:chat_stopped, self()}` — user-initiated stop
    * `{:chat_crashed, exception, stacktrace}` —
      unexpected crash

  ## Agent contract (Agent → ChatTurn, `send/2`)

    * `{:stop_chat, from}` — user clicked Stop. The
      ChatTurn replies `:stopped` to `from` and kills
      the active worker.

  The ChatTurn's `init/1` sets
  `Process.put(:"$callers", [agent_pid])` so Mimic
  stubs set on the Agent (and allowed via
  `Mimic.allow/3`) propagate to the ChatTurn's HTTP
  worker — the same mechanism `Task.async` uses for
  auto-allow. Also the worker reads the
  `:nest_test_agent_pid` from the Agent's process
  dict, which the `start_agent/1` test helper sets.
  """

  use GenServer, restart: :temporary

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatTurn.HTTPWorker
  alias Nest.Agents.Agent.ChatTurn.Messages
  alias Nest.LLM.RunResponse

  require Logger

  defmodule State do
    @moduledoc false
    defstruct agent_pid: nil,
              ctx: nil,
              iteration: 0,
              max_iterations: 0,
              force_finalize: false,
              active_worker: nil,
              active_worker_kind: nil,
              cancelled: false,
              streaming_acc: nil,
              api_log_sequences: %{},
              last_thinking: nil,
              messages_snapshot: []
  end

  # Client API

  @doc """
  Start a ChatTurn child under the ChatTurnSupervisor.
  The args are `{agent_pid, ctx}` — the ctx map carries
  everything the ChatTurn needs (client_config, tools,
  caps, context_limit, agent_id, agent_pid).
  """
  @spec start_link({pid(), map()}) :: GenServer.on_start()
  def start_link({_agent_pid, _ctx} = args) do
    GenServer.start_link(__MODULE__, args)
  end

  # Server Callbacks

  @impl true
  def init({agent_pid, ctx}) do
    Process.flag(:trap_exit, true)
    # Mimic permissions: when a test sets `Mimic.allow/3`
    # on the Agent's pid (e.g. `Mimic.allow(MockClient,
    # self(), agent_pid)`), the ChatTurn's HTTP worker
    # (spawned as a Task via `Task.Supervisor.start_child`)
    # needs to see those stubs. Mimic checks the
    # `:"$callers"` process-dict key, which the standard
    # `Task.async` sets automatically — but
    # `Task.Supervisor.start_child` does not. We set it
    # here so the worker's `MockClient.run/2` call sees
    # the test's stub.
    Process.put(:"$callers", [agent_pid])
    Process.send(self(), :iterate, [])

    state = %State{
      agent_pid: agent_pid,
      ctx: ctx,
      iteration: 0,
      max_iterations: Nest.Agents.Agent.configured_max_tool_iterations(),
      force_finalize: false,
      active_worker: nil,
      active_worker_kind: nil,
      cancelled: false,
      streaming_acc: nil,
      api_log_sequences: %{},
      last_thinking: nil,
      messages_snapshot: []
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:iterate, state), do: iterate(state)

  def handle_info({:http_response, response}, state) when is_map(response) do
    handle_response(response, state)
  end

  def handle_info({:http_error, _error}, state) do
    # The on_error callback already broadcast :llm_error to
    # the Agent and the Agent's llm_error handler transitioned
    # to :idle. We're done.
    finalize_turn(state)
  end

  def handle_info({:worker_crashed, exception, stacktrace}, state) do
    # The HTTP worker raised an unhandled exception (a
    # `FunctionClauseError` from a malformed delta, a
    # protocol error, etc.). Forward the exception +
    # stacktrace to the Agent so the Agent's
    # `chat_crashed/3` handler can finalize the partial,
    # broadcast `chat:error`, and transition to `:idle`.
    send(state.agent_pid, {:chat_crashed, exception, stacktrace})
    {:stop, :normal, state}
  end

  def handle_info({:tool_results, results}, state) do
    handle_tool_results(results, state)
  end

  def handle_info({:stop_chat, from}, state) do
    stop_chat(from, state)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    worker_exited(pid, reason, state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The iteration step. Maybe inject a budget reminder,
  # bump the iteration counter, broadcast the
  # max-iterations notification if we're at the cap,
  # query the Agent for the current messages list, and
  # spawn the HTTP worker.
  defp iterate(state) do
    state = maybe_inject_budget_reminder(state)
    state = %{state | iteration: state.iteration + 1}

    # If we've just hit the iteration cap, broadcast a
    # `chat_notification` so the UI can show a banner
    # ("Max tool iterations reached"). The OLD LLMRunner
    # did this in the `max_iterations: 0` branch of
    # `run_with_new_client/2`; we do it here before
    # making the final (tools-disabled) call.
    if state.iteration > state.max_iterations do
      Broadcasts.notification(state.ctx.agent_id, %{
        type: "max_iterations",
        message: "Max tool iterations reached"
      })
    end

    messages = GenServer.call(state.agent_pid, :get_messages)
    state = %{state | messages_snapshot: messages}

    spawn_http_worker(state)
  end

  # Check if we're approaching the iteration cap. If
  # so, build a system reminder and append it via the
  # Agent. The Agent stamps the index; the next
  # response will be stamped at `next_message_index`,
  # so no collision.
  defp maybe_inject_budget_reminder(state) do
    remaining = state.max_iterations - state.iteration

    case do_inject_budget_reminder(remaining) do
      nil ->
        state

      reminder ->
        _stamped = GenServer.call(state.agent_pid, {:append_message, reminder})
        state
    end
  end

  # Build a system reminder to inject when the iteration is
  # approaching the cap. Returns `nil` when there's no need
  # to warn (more than 2 rounds remaining, or the cap is
  # already past).
  defp do_inject_budget_reminder(remaining) when remaining > 2 or remaining <= 0, do: nil

  defp do_inject_budget_reminder(remaining) do
    warning =
      case remaining do
        2 ->
          "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

        1 ->
          "This is your last tool call round. After this, no more tools will be available — provide your final response."
      end

    {:system, %Nest.Messages.System{content: warning, timestamp: DateTime.utc_now()}}
  end

  # Spawn the HTTP worker as a Task. The worker calls
  # `Nest.LLM.Runner.request/2` and sends
  # `{:http_response, response}` or `{:http_error, error}`
  # back to the ChatTurn.
  defp spawn_http_worker(state) do
    parent = self()
    agent_pid = state.agent_pid

    # Use the streaming_acc's index for the request log
    # (this is the user message's index, which is the
    # index of the messages we're sending). If the
    # streaming_acc is nil, query the Agent for the
    # last user message.
    active_index = HTTPWorker.active_message_index(state)
    state = broadcast_request_log(state, active_index)

    # When we've hit the iteration cap, the next call
    # is the "final" call: `tools: nil, tool_choice:
    # :none` so the LLM sees the tool results and
    # produces a text response. The MockClient honors
    # `tools: nil` by skipping any queued tool
    # responses and returning the next text response.
    {tools, tool_choice} =
      if state.iteration > state.max_iterations,
        do: {nil, :none},
        else: {state.ctx.tools, state.ctx.tool_choice}

    state = %{state | ctx: %{state.ctx | tools: tools, tool_choice: tool_choice}}

    task =
      Task.Supervisor.start_child(
        Nest.Agents.TaskSupervisor,
        fn -> HTTPWorker.run(state, parent) end
      )

    case task do
      {:ok, pid} ->
        Process.monitor(pid)
        {:noreply, %{state | active_worker: pid, active_worker_kind: :http}}

      _ ->
        # Saturated supervisor. Send a crash to the Agent
        # and stop cleanly.
        send(agent_pid, {:chat_crashed, :saturated, []})
        {:stop, :normal, state}
    end
  end

  # The index of the user message (the message currently
  # being sent to the LLM). Used to seed the assistant
  # message's predicted index.
  defp active_message_index(state) do
    HTTPWorker.active_message_index(state)
  end

  # The HTTP worker returned a normalized response. Build
  # the Assistant message, append it to the Agent, then
  # dispatch on the response shape.
  defp handle_response(response, state) do
    state = %{state | active_worker: nil, active_worker_kind: nil}

    # Forward usage to the Agent so the running totals
    # update and the next chat:status push carries the
    # fresh numbers. `usage` is `nil` for clients that
    # don't populate it; the merge helper treats nil as
    # a no-op so the running totals are preserved.
    send(state.agent_pid, {:llm_usage, response.usage})

    # Build the Assistant message from the response. The
    # Agent's `tool_calls_received/2` handler stamps the
    # index and attaches the pending api_logs. We use
    # the existing handler (rather than the bare
    # `{:append_message, _}`) because it also sets the
    # Agent's status to `:executing_tools` and broadcasts
    # the status change — the same flow the old LLMRunner
    # used for tool-call messages.
    {role, msg} = build_assistant_message(response)
    msg = %{msg | index: predicted_assistant_index(state)}
    assistant_msg = {role, msg}
    send(state.agent_pid, {:tool_calls_received, assistant_msg})
    # We don't have the stamped message back here (the
    # tool_calls_received handler is async via send/2);
    # use the predicted index for the response log. The
    # api_log handler checks both the index AND a
    # fallback search, so a mismatch doesn't lose the
    # log.
    assistant_index = predicted_assistant_index(state)

    # Broadcast the response api_log to the Agent. The
    # Agent's api_log handler attaches it to the message
    # at the response's actual stamped index.
    state = broadcast_response_log(state, assistant_index, response)

    cond do
      state.force_finalize ->
        finalize_turn(state)

      RunResponse.has_tool_calls?(response) and state.iteration > state.max_iterations ->
        # Past max iterations, LLM still emitted tool
        # calls (the `tools: nil` was supposed to
        # prevent this but some providers ignore it).
        # Synthesize error tool results, recurse with
        # `force_finalize: true` so the next call
        # always finalizes regardless of what the LLM
        # does.
        tool_msg = build_synthetic_error_tool_results(response)
        _stamped_tool = GenServer.call(state.agent_pid, {:append_message, tool_msg})
        state = %{state | force_finalize: true}
        Process.send(self(), :iterate, [])
        {:noreply, state}

      RunResponse.has_tool_calls?(response) ->
        # Normal tool call: spawn the tool worker.
        spawn_tool_worker(state, response.tool_calls)

      true ->
        # Final text response.
        finalize_turn(state)
    end
  end

  # Predicted index for the assistant message. Used as
  # the `index` field on the assistant message so the
  # Agent's `tool_calls_received/2` handler's
  # `pending_api_logs(message_index)` lookup finds the
  # request log we sent at the start of the iteration.
  # The Agent's `__append_message__/2` overwrites this
  # with the actual stamped index; the lookup still
  # succeeds because the request log was sent at the
  # same predicted index.
  defp predicted_assistant_index(state) do
    active_message_index(state) + 1
  end

  # The tool worker returned a list of `ToolResult`
  # structs. Append them to the Agent as a single
  # `{:tool, _}` message, then start the next
  # iteration. We use the existing
  # `tool_results_received/2` handler (rather than bare
  # `{:append_message, _}`) because it also transitions
  # the Agent to `:streaming` and seeds a fresh
  # streaming_acc for the next iteration's response.
  defp handle_tool_results(results, state) do
    state = %{state | active_worker: nil, active_worker_kind: nil}
    tool_msg = build_tool_message(results)
    send(state.agent_pid, {:tool_results_received, tool_msg})
    Process.send(self(), :iterate, [])
    {:noreply, state}
  end

  # Spawn the tool worker as a Task. The worker calls
  # `Nest.Agents.Agent.ToolLoop.execute/3` and sends
  # `{:tool_results, results}` back to the ChatTurn.
  # The `state.ctx` map carries everything ToolLoop needs
  # (tools, caps, messages, context_limit, agent_pid).
  defp spawn_tool_worker(state, tool_calls) do
    parent = self()

    task =
      Task.Supervisor.start_child(
        Nest.Agents.TaskSupervisor,
        fn ->
          results = Nest.Agents.Agent.ToolLoop.execute(state.ctx, %{}, tool_calls)
          send(parent, {:tool_results, results})
        end
      )

    case task do
      {:ok, pid} ->
        Process.monitor(pid)
        {:noreply, %{state | active_worker: pid, active_worker_kind: :tools}}

      _ ->
        send(state.agent_pid, {:chat_crashed, :saturated, []})
        {:stop, :normal, state}
    end
  end

  # User clicked Stop. Reply `:stopped`, kill the active
  # worker, notify the Agent, and stop.
  defp stop_chat(from, state) do
    send(from, :stopped)

    if state.active_worker do
      Process.exit(state.active_worker, :kill)
    end

    state = %{state | active_worker: nil, active_worker_kind: nil, cancelled: true}
    send(state.agent_pid, {:chat_stopped, self()})
    {:stop, :normal, state}
  end

  # A worker died. `:normal` and `:killed` are expected
  # exits (the stop handler killed the worker, or the
  # tool worker completed normally). Other reasons are
  # crashes and become a `{:chat_crashed, _, _}` to
  # the Agent.
  defp worker_exited(_pid, :normal, state), do: {:noreply, state}
  defp worker_exited(_pid, :killed, state), do: {:noreply, state}

  defp worker_exited(_pid, reason, state) do
    send(state.agent_pid, {:chat_crashed, reason, []})
    {:stop, :normal, state}
  end

  # End of turn. Send `:chat_idle` and the
  # `:api_log_sequences_updated` to the Agent, then stop.
  defp finalize_turn(state) do
    send(state.agent_pid, {:chat_idle, self()})
    send(state.agent_pid, {:api_log_sequences_updated, state.api_log_sequences})
    {:stop, :normal, state}
  end

  # --- Message builders ---

  defp build_assistant_message(response) do
    Messages.assistant(response)
  end

  defp build_tool_message(results) do
    Messages.tool(results)
  end

  defp build_synthetic_error_tool_results(response) do
    Messages.synthetic_error_tool_results(response)
  end

  # --- api_log helpers ---

  defp broadcast_request_log(state, message_index) do
    Nest.Agents.Agent.ChatTurn.APILog.request(state, message_index)
  end

  defp broadcast_response_log(state, message_index, response) do
    Nest.Agents.Agent.ChatTurn.APILog.response(state, message_index, response)
  end
end

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
      streaming_acc accumulator for `get_public_info`
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

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.ChatTurn.BudgetReminder
  alias Nest.Agents.Agent.ChatTurn.Iteration
  alias Nest.Agents.Agent.ChatTurn.Lifecycle
  alias Nest.Agents.Agent.ChatTurn.Messages
  alias Nest.Agents.Agent.ChatTurn.ResponseHandler
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Messages.Part

  require Logger

  # Client API

  @doc """
  Start a ChatTurn child under the ChatTurnSupervisor.
  The args are `{agent_pid, ctx}` — the ctx map carries
  everything the ChatTurn needs (client_config, tools,
  caps, context_limit, agent_id, agent_pid).
  """
  @spec start_link({pid(), map(), State.info()}) :: GenServer.on_start()
  def start_link({_agent_pid, _ctx, _info} = args) do
    GenServer.start_link(__MODULE__, args)
  end

  # Server Callbacks

  @impl true
  def init({agent_pid, ctx, continuation}) do
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

    state = %State{
      ctx: ctx,
      iteration: initial_iteration(continuation),
      max_iterations: initial_max_iterations(continuation),
      force_finalize: false,
      active_worker: nil,
      active_worker_kind: nil,
      active_message_index: 0,
      info: continuation
    }

    Process.send(self(), :iterate, [])

    {:ok, state}
  end

  @impl true
  def handle_info(:iterate, state), do: iterate(state)

  def handle_info({:http_response, response}, state) when is_map(response) do
    # Check for a pending stop before processing the response.
    # The worker sends `{:http_response, _}` when it finishes
    # the stream. The agent sends `{:stop_chat, _}` when the
    # user clicks Stop. If both are in the mailbox, the stop
    # must be processed first — otherwise the chat turn would
    # finalize the full response and `stop_chat/2` would never
    # run, so the partial message (with `stopped_by_user: true`)
    # would never be appended. This is the racy case: the
    # worker finishes its 1000-event stream in microseconds
    # (MockClient yields events instantly), the test receives
    # the first delta and calls stop, but the stop arrives at
    # the chat turn AFTER the http_response. Without this
    # check, the chat turn would finalize and stop, discarding
    # the stop message. With it, we honor the user's intent.
    case Lifecycle.drain_stop_message() do
      {:stop, from} -> Lifecycle.stop_chat(from, state)
      nil -> handle_response(response, state)
    end
  end

  def handle_info({:http_error, _error}, state) do
    # The on_error callback already broadcast :llm_error to
    # the Agent and the Agent's llm_error handler transitioned
    # to :idle. We're done.
    Lifecycle.finalize_turn(state)
  end

  def handle_info({:worker_crashed, exception, stacktrace}, state) do
    # The HTTP worker raised an unhandled exception (a
    # `FunctionClauseError` from a malformed delta, a
    # protocol error, etc.). Forward the exception +
    # stacktrace to the Agent so the Agent's
    # `chat_crashed/3` handler can finalize the partial,
    # broadcast `chat:error`, and transition to `:idle`.
    send(state.ctx.agent_pid, {:chat_crashed, exception, stacktrace})
    {:stop, :normal, state}
  end

  def handle_info({:tool_results, results}, state) do
    handle_tool_results(results, state)
  end

  def handle_info({:stop_chat, from}, state) do
    Lifecycle.stop_chat(from, state)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Lifecycle.worker_exited(pid, reason, state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The iteration step. Wrapped in an implicit `try/catch` so
  # a dead agent (e.g. `Agent.terminate/1` mid-turn) doesn't
  # crash the ChatTurn with an unhandled `:exit` from
  # `GenServer.call/2` — we just stop cleanly.
  defp iterate(state) do
    safe_iterate(state)
  catch
    :exit, _ -> {:stop, :normal, state}
  end

  defp safe_iterate(state) do
    state = maybe_inject_budget_reminder(state)
    state = %{state | iteration: state.iteration + 1}

    Iteration.notify_max_iterations(state)

    {messages, cancelled} = GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled)
    next_index = GenServer.call(state.ctx.agent_pid, :get_next_index)
    state = %{state | active_message_index: next_index}

    iteration_branch(state, messages, cancelled)
  end

  # The branching logic for `safe_iterate/1`'s three cases.
  # Extracted into its own function to keep `safe_iterate`'s
  # ABC size under credo's limit. Returns the same
  # `GenServer.reply` tuple as `safe_iterate/1` did.
  #
  # The continuation carries the resume payload:
  #
  #   * `{:tool_call, _, _, _}` → tail has `assistant+ToolUse`
  #     (Trigger 2). First iter runs the carried tool calls.
  #   * `{:compact_tool, _, _, _}` → tail has the synthetic
  #     `tool` result (Trigger 3). First iter falls through to
  #     the LLM (the resume pays no preflight tax since the
  #     tool was already executed/baked-in by the trigger site).
  #   * `nil` or `{:user_message, _}` → tail has the user
  #     message (Trigger 1). First iter falls through to the
  #     LLM via `dispatch_batch`.
  #
  # The messages list is correctly shaped by construction (the
  # continuation structure carries it through the compactor's
  # swap). No post-resume defensive checks.
  defp iteration_branch(state, messages, cancelled) do
    cond do
      cancelled ->
        Iteration.finalize_cancelled(state)

      pending_tool_calls?(messages) ->
        execute_pending_tool_calls(state, messages)

      true ->
        Iteration.dispatch_batch(state, messages)
    end
  end

  # Detect that the LLM has already responded with tool calls and
  # we're waiting to execute them. The last message must be an
  # assistant message containing at least one `%Part.ToolUse{}`.
  defp pending_tool_calls?(messages) do
    case List.last(messages) do
      {:assistant, %{parts: parts}} when is_list(parts) ->
        Enum.any?(parts, &match?(%Part.ToolUse{}, &1))

      _ ->
        false
    end
  end

  # Mid-turn resume: the LLM has already responded with tool calls
  # (the assistant message is at the end of messages). Extract the
  # tool calls from the parts, re-preflight as defense in depth, and
  # either execute them or signal `:needs_compaction` if the
  # compactor's output is still too big.
  #
  # `context.compact` is filtered out because it doesn't go through
  # BatchSizer — ToolLoop handles it via the GenServer round-trip.
  defp execute_pending_tool_calls(state, messages) do
    [{:assistant, %{parts: parts}} | _] = Enum.reverse(messages)
    tool_calls = ResponseHandler.extract_tool_calls_from_parts(parts)

    case BatchSizer.preflight(ToolLoop.strip_context_compact(tool_calls), state.ctx) do
      :fits ->
        spawn_tool_worker(state, tool_calls)

      {:refuse, _reason} ->
        # Compactor didn't reduce enough. Trigger another compaction.
        send(
          state.ctx.agent_pid,
          {:needs_compaction, self(), state.iteration, state.max_iterations}
        )

        {:stop, :normal, state}
    end
  end

  # Resolve the iteration count from the continuation. Both tool
  # continuations (`{:tool_call, _, _, _}` and
  # `{:compact_tool, _, _, _}`) carry their iteration count +
  # max_iterations through the compaction boundary so the
  # tool-call iteration cap is enforced continuously across
  # both trigger types. The `{:user_message, _}` and `nil`
  # shapes start fresh (iteration 0, default max).
  defp initial_iteration({_tag, _msg, n, _max}) when is_integer(n), do: n
  defp initial_iteration(_), do: 0

  defp initial_max_iterations({_tag, _msg, _n, m}) when is_integer(m), do: m
  defp initial_max_iterations(_), do: Config.configured_max_tool_iterations()

  # Check if we're approaching the iteration cap. If
  # so, build a system reminder and append it via the
  # Agent. The Agent stamps the index; the next
  # response will be stamped at `next_message_index`,
  # so no collision.
  defp maybe_inject_budget_reminder(state) do
    remaining = state.max_iterations - state.iteration

    case BudgetReminder.build(remaining) do
      nil ->
        state

      reminder ->
        _stamped = GenServer.call(state.ctx.agent_pid, {:append_message, reminder})
        state
    end
  end

  # Delegate response handling to `ChatTurn.ResponseHandler`
  # to keep this module under the 500-line credo cap.
  defp handle_response(response, state) do
    ResponseHandler.handle(response, state, self())
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
    tool_msg = Messages.tool(results)
    send(state.ctx.agent_pid, {:tool_results_received, tool_msg})
    Process.send(self(), :iterate, [])
    {:noreply, state}
  end

  # Spawn the tool worker as a Task. The worker calls
  # `Nest.Agents.Agent.ToolLoop.execute/3` and sends
  # `{:tool_results, results}` back to the ChatTurn.
  # The `state.ctx` map carries everything ToolLoop needs
  # (tools, caps, messages, context_limit, agent_pid).
  def spawn_tool_worker(state, tool_calls) do
    parent = self()

    task =
      Task.Supervisor.start_child(
        Nest.Agents.TaskSupervisor,
        fn ->
          results = ToolLoop.execute(state.ctx, %{}, tool_calls)
          send(parent, {:tool_results, results})
        end
      )

    case task do
      {:ok, pid} ->
        Process.monitor(pid)
        {:noreply, %{state | active_worker: pid, active_worker_kind: :tools}}

      _ ->
        send(state.ctx.agent_pid, {:chat_crashed, :saturated, []})
        {:stop, :normal, state}
    end
  end
end

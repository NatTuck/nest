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
    * `{:compaction_done, summary_text, carried_entry}` —
      compactor's own chat turn finished; the Agent's
      `Compaction.ResultHandler` takes over from here

  ## Agent contract (Agent → ChatTurn, `GenServer.call`)

    * `{:stop_chat, channel_pid}` — user clicked Stop. The
      ChatTurn's `handle_call/3` replies `:ok` AFTER
      `Lifecycle.stop_chat/2` has acked `:stopped` to
      `channel_pid`, killed the active worker (with the
      stop-aware cleanup hook), and cast `{:chat_stopped,
      self()}` to the Agent. The 5s call timeout in the
      Agent's handler breaks the rare deadlock where the
      ChatTurn is itself blocked on `safe_iterate/1`'s
      `GenServer.call(agent, :get_messages_with_cancelled)`.

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
  The args are `{agent_pid, ctx, entry}` — the ctx map
  carries everything the ChatTurn needs (client_config,
  tools, caps, context_limit, agent_id, agent_pid).
  """
  @spec start_link({pid(), map(), State.entry()}) :: GenServer.on_start()
  def start_link({_agent_pid, _ctx, _entry} = args) do
    GenServer.start_link(__MODULE__, args)
  end

  # Server Callbacks

  @impl true
  def init({agent_pid, ctx, entry}) do
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
      iteration: initial_iteration(entry),
      max_iterations: initial_max_iterations(entry),
      force_finalize: false,
      active_worker: nil,
      active_worker_kind: nil,
      active_message_index: 0,
      stop_requested: false,
      entry: entry
    }

    Process.send(self(), :iterate, [])

    {:ok, state}
  end

  @impl true
  def handle_info(:iterate, state), do: iterate(state)

  def handle_info({:http_response, response}, state) when is_map(response) do
    # The user clicked Stop while the HTTP worker was finishing
    # the stream. Skip response processing if the Agent's
    # `cancelled` flag is set — appending a full response
    # would leave a second assistant message after the
    # cancelled-by-user placeholder. The flag is set
    # synchronously by the Agent's `handle_call({:stop_chat, _})`
    # before it calls us, so a `GenServer.call` here with a
    # short timeout returns the latest value. On timeout
    # (rare — Agent is blocked), `cancelled?/1` defaults to
    # `false` and we proceed; the cancelled flag is also
    # picked up by `safe_iterate/1`'s same call (without a
    # timeout) on the next iteration.
    if cancelled?(state) do
      GenServer.cast(state.ctx.agent_pid, {:chat_stopped, self()})
      {:stop, :normal, state}
    else
      handle_response(response, state)
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

  def handle_info({:EXIT, pid, reason}, state) do
    Lifecycle.worker_exited(pid, reason, state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # User clicked Stop. The Agent's `handle_call({:stop_chat, _})`
  # propagates the stop here via `GenServer.call` (per SMELLS.md
  # — no `send` between our own GenServers). The ChatTurn's
  # reply is sent AFTER `Lifecycle.stop_chat/2` kills the
  # active worker and casts `{:chat_stopped, _}` to the
  # Agent, so when the Agent's GenServer.call returns, the
  # Agent immediately processes the `:chat_stopped` cast
  # from its mailbox and broadcasts `:idle`.
  @impl true
  def handle_call({:stop_chat, channel_pid}, _from, state) do
    Lifecycle.stop_chat(channel_pid, state)
  end

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
  # The entry carries the resume payload:
  #
  #   * `{:tool_call, _, _, _}` → tail has `assistant+ToolUse`
  #     (Trigger 2). First iter runs the carried tool calls.
  #   * `{:compact_tool, _, _, _}` → tail has the synthetic
  #     `tool` result (Trigger 3). First iter falls through to
  #     the LLM (the resume pays no preflight tax since the
  #     tool was already executed/baked-in by the trigger site).
  #   * `{:user_message, _}` → tail has the user
  #     message (Trigger 1). First iter falls through to the
  #     LLM via `dispatch_batch`.
  #   * `{:compaction, _, _}` → compactor's own chat turn.
  #     First iter dispatches with `tools: nil, tool_choice: :none`
  #     (no budget reminder, no context warning — this is a
  #     one-shot summarization call).
  #
  # The messages list is correctly shaped by construction (the
  # entry structure carries it through the compactor's
  # swap). No post-resume defensive checks.
  defp iteration_branch(state, messages, cancelled) do
    cond do
      cancelled ->
        Iteration.finalize_cancelled(state)

      pending_tool_calls?(messages) ->
        execute_pending_tool_calls(state, messages)

      compactor_entry?(state) ->
        Iteration.dispatch_compaction(state, messages)

      true ->
        Iteration.dispatch_batch(state, messages)
    end
  end

  # True when this ChatTurn is the compactor's own chat turn.
  # The entry shape `{:compaction, _, _}` tells us to dispatch
  # with `tools: nil, tool_choice: :none` (no tool calls in a
  # summarization request) and the iteration cap is irrelevant
  # (a single LLM call is the whole job).
  defp compactor_entry?(%State{entry: {:compaction, _, _}}), do: true
  defp compactor_entry?(_), do: false

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
  # `context-compact` is filtered out because it doesn't go through
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

  # Resolve the iteration count from the entry. Both tool
  # entries (`{:tool_call, _, _, _}` and
  # `{:compact_tool, _, _, _}`) carry their iteration count +
  # max_iterations through the compaction boundary so the
  # tool-call iteration cap is enforced continuously across
  # both trigger types. The `{:user_message, _}` and
  # `{:compaction, _, _}` shapes start fresh (iteration 0,
  # default max).
  defp initial_iteration({_tag, _msg, n, _max}) when is_integer(n), do: n
  defp initial_iteration(_), do: 0

  defp initial_max_iterations({_tag, _msg, _n, m}) when is_integer(m), do: m
  defp initial_max_iterations(_), do: Config.configured_max_tool_iterations()

  # Check if we're approaching the iteration cap. If
  # so, set `pending_notice` on the ChatTurn state so
  # the notice attaches to the next tool response or
  # synthetic pair.
  defp maybe_inject_budget_reminder(state) do
    remaining = state.max_iterations - state.iteration

    case BudgetReminder.notice_text(remaining) do
      nil ->
        state

      notice ->
        %{state | pending_notice: state.pending_notice || notice}
    end
  end

  # Delegate response handling to `ChatTurn.ResponseHandler`
  # to keep this module under the 500-line credo cap.
  defp handle_response(response, state) do
    ResponseHandler.handle(response, state, self())
  end

  # The tool worker returned a list of `ToolResult`
  # structs. Append them to the Agent as a single
  # `{:tool, _}` message, then start the next iteration.
  # Threshold announcements are handled by the ChatTurn's
  # response-construction path (ResponseHandler) before the
  # next LLM call, not here — attaching a `Part.Text` to a
  # `{:tool, _}` message breaks the OpenAI wire format
  # (the formatter destructures mixed parts into separate
  # wire messages, separating the tool_result from its
  # tool_use).
  #
  # If the user clicked Stop while the tool was finishing,
  # `cancelled?/1` returns true and we skip the append —
  # otherwise the message list would carry both the tool
  # result and the cancelled-by-user placeholder.
  defp handle_tool_results(results, state) do
    state = %{state | active_worker: nil, active_worker_kind: nil}

    if cancelled?(state) do
      GenServer.cast(state.ctx.agent_pid, {:chat_stopped, self()})
      {:stop, :normal, state}
    else
      tool_msg = Messages.tool(results)

      send(state.ctx.agent_pid, {:tool_results_received, tool_msg})
      state = %{state | pending_notice: nil}
      Process.send(self(), :iterate, [])
      {:noreply, state}
    end
  end

  # Synchronous cancelled-flag read from the Agent. 100ms
  # timeout prevents deadlock if the Agent is itself blocked
  # (e.g. on the `GenServer.call({:stop_chat, _})` chain).
  # On timeout, defaults to `false` — `safe_iterate/1` makes
  # the same call without a timeout on the next iteration,
  # so the flag is eventually observed.
  defp cancelled?(state) do
    {_messages, cancelled} =
      GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled, 100)

    cancelled
  catch
    :exit, _ -> false
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

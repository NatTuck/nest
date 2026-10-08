defmodule Nest.Agents.Agent.AsyncWaiter do
  @moduledoc """
  Supervised waiter for the async modes of `agents-spawn` and
  `agents-query`.

  With `async: true` the tool worker returns immediately; the wait for
  the outcome must still not run in the calling agent's GenServer, and
  there is no blocking tool worker left to own it. So the waiter is a
  Task under `Nest.Agents.TaskSupervisor` that:

    * monitors the calling agent and exits quietly (no crash report, no
      log) when it is gone;
    * is bounded by a single wall-clock `timeout` in every path;
    * delivers the outcome to the calling agent's inbox via
      `Nest.Agents.Agent.deliver_message/3` — the same path
      `agents-send` uses — with a one-line note naming the call and a
      body identical to what the blocking path returns
      (`Nest.Agents.Agent.SubAgentResults`).

  A timeout is a normal result, delivered as a message, never an error.

  ## Limits

  A waiter's outcome is not always delivered, so the tool descriptions
  cannot promise otherwise:

    * **A Stop does not cancel a waiter.** Stopping the child (or the
      caller's turn) does not cancel this task. The caller drops the
      child's tracking entry without forwarding a result —
      `{:stop_all_children}` clears the `Children` sub-machine and stops
      the child, and the per-item `:abandoned` transition emits only
      `{:stop_child, name}` — so no `{:spawn_agent_result, ...}` ever
      arrives and the waiter delivers a timeout notice when its deadline
      expires. That timeout notice is what a user sees after pressing
      Stop.
    * **A refused delivery loses the result.** If the calling agent is in
      a broken status (`:needs_repair`, `:context_overflow`,
      `:compaction_failed`, `:model_missing`) or its inbox is full,
      `Agent.deliver_message/3` refuses. The waiter logs a warning and
      broadcasts a `chat_notification` on the caller's own topic so the
      user sees that a result was lost; the model never sees it. A caller
      that is simply already gone (`:noproc`/`:normal`) stays quiet.
    * **A rebuilt caller loses the child entry.** `Children.step/2`
      ignores an event for an unknown child, so a caller whose machine was
      recreated (recovery/repair) gets a false `[agents-spawn timed out]`
      for a child that did complete.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.PeerQuery
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Messages.ToolCall

  @doc """
  Start a supervised waiter for an async `agents-spawn`. Returns the
  `Task.Supervisor.start_child/3` result.
  """
  @spec start_spawn(pid(), map(), ToolCall.t(), timeout()) :: {:ok, pid()} | {:error, term()}
  def start_spawn(parent_pid, ctx, tc, timeout) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      spawn_wait(parent_pid, ctx, tc, timeout)
    end)
  end

  @doc """
  Start a supervised waiter for an async `agents-query`. Returns the
  `Task.Supervisor.start_child/3` result.
  """
  @spec start_query(pid(), map(), ToolCall.t(), String.t(), String.t(), timeout()) ::
          {:ok, pid()} | {:error, term()}
  def start_query(parent_pid, ctx, tc, target, prompt, timeout) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      query_wait(parent_pid, ctx, tc, target, prompt, timeout)
    end)
  end

  # -- agents-spawn --

  # The worker starts us before it calls the coordinator, so the child's
  # completion can never be forwarded to a not-yet-existing process. We
  # wait for the worker's verdict: the spawned name (go) or an abandon
  # (the spawn failed synchronously). We also accept a result/error that
  # beat the go signal — if the worker died (or its spawn call timed out)
  # after the child was spawned, the outcome may already be waiting, and
  # discarding it would lose the result. One deadline bounds both phases,
  # so a worker that never signals cannot strand us past `timeout`.
  defp spawn_wait(parent_pid, ctx, tc, timeout) do
    ref = Process.monitor(parent_pid)
    deadline = System.monotonic_time(:millisecond) + timeout

    receive do
      {:spawn_agent_go, name} ->
        await_spawn(parent_pid, ref, ctx, tc, name, deadline)

      {:spawn_agent_result, name, response} ->
        deliver_spawn_result(parent_pid, ctx, tc, name, response)

      {:spawn_agent_error, name, reason} ->
        deliver_spawn_error(parent_pid, ctx, name, reason)

      :spawn_agent_abandon ->
        :ok

      {:DOWN, ^ref, :process, ^parent_pid, _reason} ->
        :ok
    after
      remaining(deadline) -> :ok
    end
  end

  defp await_spawn(parent_pid, ref, ctx, tc, name, deadline) do
    receive do
      {:spawn_agent_result, _name, response} ->
        deliver_spawn_result(parent_pid, ctx, tc, name, response)

      {:spawn_agent_error, _name, reason} ->
        deliver_spawn_error(parent_pid, ctx, name, reason)

      {:DOWN, ^ref, :process, ^parent_pid, _reason} ->
        :ok
    after
      remaining(deadline) -> deliver_spawn_timeout(parent_pid, ctx, name)
    end
  end

  # The remaining slice of the single deadline. Clamped at zero so an
  # already-elapsed budget means "check the mailbox, then time out".
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp deliver_spawn_result(parent_pid, ctx, tc, name, "") do
    deliver(
      parent_pid,
      ctx,
      name,
      "[agents-spawn failed]",
      SubAgentResults.spawn_completed(ctx, tc, name, "")
    )
  end

  defp deliver_spawn_result(parent_pid, ctx, tc, name, response) do
    deliver(
      parent_pid,
      ctx,
      name,
      "[agents-spawn result]",
      SubAgentResults.spawn_completed(ctx, tc, name, response)
    )
  end

  defp deliver_spawn_error(parent_pid, ctx, name, reason) do
    deliver(
      parent_pid,
      ctx,
      name,
      "[agents-spawn failed]",
      SubAgentResults.spawn_child_failed(name, reason)
    )
  end

  defp deliver_spawn_timeout(parent_pid, ctx, name) do
    deliver(parent_pid, ctx, name, "[agents-spawn timed out]", SubAgentResults.spawn_timeout())
  end

  # -- agents-query --

  # The single bounded wait lives inside `PeerQuery` (its deadline starts
  # when the query does), so there is no second window here.
  defp query_wait(parent_pid, ctx, tc, target, prompt, timeout) do
    case PeerQuery.run(ctx.space_id, target, prompt, timeout, parent_pid) do
      :parent_down ->
        :ok

      {:ok, content} ->
        deliver(
          parent_pid,
          ctx,
          target,
          "[agents-query result]",
          SubAgentResults.query_success(ctx, tc, content)
        )

      {:error, {:timeout, ms}} ->
        deliver(
          parent_pid,
          ctx,
          target,
          "[agents-query timed out]",
          SubAgentResults.query_failure({:timeout, ms}, target)
        )

      {:error, reason} ->
        deliver(
          parent_pid,
          ctx,
          target,
          "[agents-query failed]",
          SubAgentResults.query_failure(reason, target)
        )
    end
  end

  # -- delivery --

  # Deliver the noted body to the calling agent's inbox. A refused
  # delivery (broken target status or full inbox) or a call timeout means
  # the result was lost — noteworthy, so log a warning *and* broadcast a
  # notification on the caller's own topic: the tool told the model the
  # response would arrive later as a message, so when it cannot, the user
  # must see why (UI transparency). A target that is already gone is
  # expected (the waiter monitors it and can lose the race between the
  # DOWN and this call), so `:noproc`/`:normal` exits stay quiet.
  defp deliver(parent_pid, ctx, sender, note, body) do
    case Agent.deliver_message(parent_pid, sender, note <> "\n" <> body) do
      {:ok, _result} -> :ok
      {:error, reason} -> delivery_failed(ctx, parent_pid, sender, reason)
    end
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
    :exit, reason -> delivery_failed(ctx, parent_pid, sender, {:exit, reason})
  end

  defp delivery_failed(ctx, parent_pid, sender, reason) do
    Logger.warning(
      "async sub-agent result could not be delivered to #{inspect(parent_pid)}: #{inspect(reason)}"
    )

    Broadcasts.notification(ctx.space_id, ctx.agent_name, %{
      type: "async_delivery_failed",
      message:
        "An async result from #{sender} could not be delivered: " <>
          "#{delivery_reason(reason)}."
    })
  end

  # Human-readable delivery refusal for the notification banner.
  defp delivery_reason(:inbox_full), do: "the agent's inbox is full"
  defp delivery_reason({:status, status}), do: "the agent is in a #{status} state"
  defp delivery_reason({:exit, reason}), do: "the delivery call exited: #{inspect(reason)}"
  defp delivery_reason(reason), do: inspect(reason)
end

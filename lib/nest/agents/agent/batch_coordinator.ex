defmodule Nest.Agents.Agent.BatchCoordinator do
  @moduledoc """
  The supervised coordinator for one `agents-batch` call (issue #31 §2.3).

  The tool call returns as soon as the batch is launched: the fan-out does not
  happen in the tool worker and nothing waits for the children. This process —
  a supervised task, not the worker — spawns them (paced to
  `max_concurrency`), watches each outcome arrive, abandons a child past its
  per-item deadline, and finally enqueues the aggregate: a JSON array of the
  slots in item order, delivered into the parent's own inbox as a runtime
  `:notice`.

  ## Reading the children's outcomes

  §2.1 delivers a child's outcome in the *parent's* process, so the parent is
  the one that routes it: a child spawned with `report_to` set to this
  coordinator reports here, and the parent's executor `send`s the outcome
  straight into this process's mailbox. Nothing subscribes to a topic and no
  worker pid is tracked; this mailbox exists before the first child does, since
  this process is the one sending the spawn requests, so an outcome cannot
  precede the child it is about.

  A child's *notice* (it failed, was stopped, or finished without producing any
  text) is a failed slot: the marker keeps the notice's own wording, so the
  aggregate says what happened rather than only that something did. Under
  `on_error: "fail_fast"` the first such slot stops the rest.

  ## Deadlines and abandonment

  `timeout` is per item, measured from that child's spawn. An item past its
  deadline is abandoned through the parent (`{:abandon_child, …}`): the parent's
  own batch asked for that stop, so — by the ruling in `Machine.Children` — no
  notice is enqueued for it, and this coordinator writes the timeout marker
  itself.

  A spawn that cannot proceed (max depth, a bad vocation) is reported in the
  inbox as well, for the same reason: by then the call has already returned its
  confirmation. A whole-call failure that is knowable *before* the launch (bad
  items, a bad glob, a template with no placeholder) stays the tool result.

  ## What a killed coordinator loses

  A Stop kills this process — the parent's stop transition emits a kill for
  every distinct reporting target, before it clears its children map — and the
  parent then refuses any spawn request this process had already sent
  (`SubAgent.handle_spawn_request/3` returns `{:error, :stopping}` for the
  whole stop window, and `step/2` exits quietly on it). So a request already in
  flight when the stop lands starts nothing, and the parent is not told the
  batch was lost (it asked).

  **Known residual:** that refusal is scoped to the `:stopping` phase, so a
  request that lands *after* the stop has finished is accepted. A coordinator
  the stop killed cannot produce one (a process with a pending `:kill` cannot
  run again), so reaching it needs a coordinator the stop did not kill — one
  that was never a reporting target — whose first `GenServer.call` is delayed
  past `stop_fallback_ms` (2 s in production, 1 ms in tests). Such a request
  would spawn a child that reports to a coordinator that may be gone, which the
  children sub-machine already degrades to per-child messages; if that
  coordinator is gone too, its `:DOWN` is reported as a lost batch. No
  practically reachable path to it was found, and no code chases it.

  Two holes are accepted rather than closed: an outcome already in this mailbox
  when the kill lands dies with it, and the parent's delivery of an outcome
  races this process's death (`Process.alive?` then `send/2` in the executor),
  so such an outcome is dropped rather than falling back to the parent's inbox.
  A child that has *not* reported yet is unaffected: with the target gone, its
  delivery falls back to the parent's inbox, which is what
  `Turn.notice_lost_batch/3` means by "children still running". Holding the
  answers in the parent instead would close both holes and reintroduce one
  message per child, which the aggregate exists to remove.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchPlan
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Messages.ToolCall

  # Spawn and abandon requests are local GenServer calls into the parent; a
  # generous but finite bound so a wedged parent cannot hang the batch forever.
  @call_timeout_ms 30_000

  @doc """
  Launch the batch and return the confirmation the model reads. A call that
  cannot be planned at all is an immediate error result.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, tc) do
    args = tc.arguments || %{}

    with {:ok, items} <- BatchPlan.resolve_items(args, ctx),
         {:ok, template} <- BatchPlan.template_ok(Map.get(args, "template", "")) do
      start(ctx, tc, BatchPlan.new(ctx, args, items, template))
    else
      {:error, reason} -> {:error, BatchPlan.error_message(reason)}
    end
  end

  defp start(ctx, tc, plan) do
    case Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
           # `$callers` keeps this task inside the parent's caller chain, so
           # anything it does that reaches a pooled resource is attributed to
           # the parent. The property holds because the coordinator needs no
           # database access of its own: the plan's reads (the children's names)
           # already happened in the tool worker, via `BatchPlan.new/4`, and
           # everything here is either pure or a call into the parent, which
           # owns its own connection.
           Process.put(:"$callers", [ctx.agent_pid])
           coordinate(plan, tc)
         end) do
      {:ok, _pid} -> {:ok, confirmation(plan)}
      {:error, reason} -> {:error, "Could not start the batch coordinator: #{inspect(reason)}"}
    end
  end

  # The confirmation the model reads: where the answers go, that the aggregate
  # follows, and what a slot says when a child did not answer. Never
  # "asynchronously" — nothing here has a synchronous mode to contrast with.
  #
  # The children report to the coordinator, not to the parent, so this must NOT
  # promise per-child messages: the aggregate is where the parent reads what
  # they said.
  defp confirmation(plan) do
    "Fanned #{length(plan.items)} item(s) out to #{Enum.join(plan.names, ", ")}. " <>
      "The aggregate — a JSON array of their answers, in item order — will " <>
      "arrive as a message in your inbox when the batch finishes; each child " <>
      "reports to the batch, so the aggregate is where you read what they said. " <>
      "A child that fails, is stopped, or produces no text becomes an " <>
      "[error: ...] marker in its slot#{fail_fast_note(plan)}"
  end

  # `fail_fast` is the one case where a slot is not always a marker: the batch
  # stops at the first failure, so the slots it never reached say that instead.
  defp fail_fast_note(%{on_error: "fail_fast"}) do
    "; with `on_error: \"fail_fast\"` the batch stops at the first failure and " <>
      "reports the slots it filled before it stopped."
  end

  defp fail_fast_note(_plan), do: "."

  # ---- the coordinator itself ----

  # The children report to *this* process (the spawn opts carry it), so their
  # outcomes land in this mailbox — which exists before the first spawn, since
  # this process is the one sending the spawn requests. An outcome cannot
  # precede the child it is about, so nothing can be missed.
  defp coordinate(plan, tc) do
    step(plan, tc)
  rescue
    error -> report_crash(plan, tc, Exception.message(error))
  catch
    :exit, reason -> report_crash(plan, tc, "exited: #{inspect(reason)}")
    :throw, reason -> report_crash(plan, tc, "threw: #{inspect(reason)}")
  end

  # A coordinator that stops before its final act says so: the batch is not
  # silently incomplete. The slots already filled go with the notice, so a
  # child's answer that arrived before the crash is not lost with it. The
  # children's own answers do not depend on this process — with the target gone,
  # their delivery falls back to the parent's inbox, except for an outcome this
  # process had already received (see "What a killed coordinator loses").
  defp report_crash(plan, tc, reason) do
    Logger.error("[batch] coordinator stopped before the aggregate: #{reason}")

    deliver(
      stopped_notice(
        plan,
        tc,
        "The batch of #{length(plan.items)} item(s) stopped before its aggregate: #{reason}"
      ),
      plan
    )
  end

  # Re-pace to fill the slots that just freed, then keep consuming.
  #
  # `:stopping` is not a spawn failure: the parent is unwinding a Stop the user
  # asked for, it has already stopped this batch's children, and reporting "the
  # batch stopped: could not spawn" would be telling the model about a stop it
  # did not cause. The coordinator exits quietly instead.
  defp step(plan, tc) do
    case pace(plan) do
      {:ok, plan} ->
        drain(plan, tc)

      {:error, :stopping} ->
        :ok

      {:error, reason} ->
        finish_failure(plan, tc, BatchPlan.spawn_error_message(reason))
    end
  end

  # Spawn the next item while under the concurrency cap and items remain.
  defp pace(plan) do
    if plan.spawned >= length(plan.items) or map_size(plan.pending) >= plan.max_concurrency do
      {:ok, plan}
    else
      index = plan.next
      item = Enum.at(plan.items, index)
      name = Enum.at(plan.names, index)

      opts =
        Map.merge(plan.base_opts, %{
          name: name,
          query: BatchPlan.render(plan.template, index, item),
          report_to: self()
        })

      case spawn_child(plan.parent, opts) do
        {:ok, ^name} ->
          now = System.monotonic_time(:millisecond)

          plan
          |> Map.put(:pending, Map.put(plan.pending, name, {index, now + plan.timeout_ms}))
          |> Map.update!(:next, &(&1 + 1))
          |> Map.update!(:spawned, &(&1 + 1))
          |> pace()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Consume outcomes one at a time, re-pacing as slots free, until every slot is
  # filled (by an answer, a notice marker, or a timeout marker).
  defp drain(%{pending: pending} = plan, tc) when map_size(pending) == 0, do: finish(plan, tc)

  defp drain(plan, tc) do
    receive do
      {:child_message, name, result} -> on_outcome(plan, tc, name, result)
    after
      next_wait(plan) -> on_deadlines(plan, tc)
    end
  end

  # One child's outcome, reported to this process by the parent's executor.
  # `SubAgentResults.child_message/2` is the same wording the parent would have
  # delivered, so a batch slot says exactly what the parent's own message would
  # have said.
  defp on_outcome(plan, tc, name, result) do
    case Map.fetch(plan.pending, name) do
      {:ok, {index, _deadline}} ->
        {content, kind} = SubAgentResults.child_message(name, result)
        failed? = kind != :agent
        value = if failed?, do: BatchPlan.marker(content), else: content
        plan = set_done(plan, index, value, name)

        if failed? and plan.on_error == "fail_fast" do
          finish_failure(plan, tc, "item #{index} failed: #{content}")
        else
          step(plan, tc)
        end

      :error ->
        # An outcome for a child this batch already abandoned (a completion
        # racing its timeout): not mine to place.
        drain(plan, tc)
    end
  end

  # Abandon every child past its deadline and write a timeout marker into each
  # of their slots.
  defp on_deadlines(plan, tc) do
    now = System.monotonic_time(:millisecond)

    {timed_out, remaining} =
      Map.split_with(plan.pending, fn {_name, {_index, deadline}} -> deadline <= now end)

    plan = abandon_timed_out(timed_out, %{plan | pending: remaining})

    # No "nothing pending left → finish" arm: with `max_concurrency` at its floor
    # of 1, the last pending child can time out while items remain unspawned, and
    # finishing there would silently drop every one of them (their slots would go
    # out as "no result"). `step/2` paces the remaining items, and `drain/2`'s
    # guard clause finishes once nothing is left to spawn.
    if plan.on_error == "fail_fast" and map_size(timed_out) > 0 do
      finish_failure(plan, tc, "an item timed out after #{plan.timeout_ms}ms")
    else
      step(plan, tc)
    end
  end

  # Abandon each timed-out child and write its marker. The parent's own batch
  # asked for the stop, so it enqueues no notice (the `Machine.Children`
  # abandonment ruling) — this marker is the only report of it.
  defp abandon_timed_out(timed_out, plan) do
    Enum.reduce(timed_out, plan, fn {name, {index, _deadline}}, plan ->
      abandon(plan.parent, name)
      set_done(plan, index, BatchPlan.marker("timed out after #{plan.timeout_ms}ms"), name)
    end)
  end

  # ---- finishing ----

  # Every slot is filled: assemble the ordered aggregate and enqueue it.
  defp finish(plan, tc) do
    plan.ctx
    |> BatchPlan.assemble(tc, plan.results)
    |> deliver(plan)
  end

  # `fail_fast`, a spawn that could not proceed, or a timeout under `fail_fast`:
  # stop the rest and report it in the inbox. The slots already filled go with
  # the notice — a child's answer that arrived before the stop is not discarded
  # along with the rest.
  #
  # Stopping is not free: each `abandon/2` below is a `GenServer.call` into the
  # parent, bounded by `@call_timeout_ms`, and the parent's own `{:stop_child}`
  # runs `GiveUpDelivery.give_up_before_stop/2`, which makes *two* bounded
  # `:sys` calls when the child owes replies (`:sys.get_state/2` and
  # `:sys.replace_state/3`, each up to `GiveUpDelivery`'s 1s state timeout). So
  # one wedged child can hold the parent ~2s, and this `Enum.each` walks every
  # pending child in turn — the loop itself is not bounded by
  # `@call_timeout_ms`, only each call is. Bounded by the batch size and rare,
  # but this is where that time goes.
  defp finish_failure(plan, tc, reason) do
    Enum.each(Map.keys(plan.pending), &abandon(plan.parent, &1))

    deliver(stopped_notice(plan, tc, "Batch of #{length(plan.items)} stopped: #{reason}"), plan)
  end

  # Why the batch stopped, then the slots it filled before that (the rest say
  # "not run"), in item order — so the model reads the answers it did get next
  # to the reason it did not get the others.
  defp stopped_notice(plan, tc, reason) do
    "#{reason}\nThe batch's slots, in item order:\n" <>
      BatchPlan.assemble_stopped(plan.ctx, tc, plan.results)
  end

  # The final act: the aggregate goes into the parent's own inbox, as the
  # runtime's notice (no agent said it).
  #
  # Through the cap-bypassing internal path, not `deliver_message/4`: the
  # aggregate is the parent's *own* result, and the peer-inbox cap would refuse
  # it with `:inbox_full`, after which this coordinator would log a warning, exit
  # `:normal`, and the batch's whole output would vanish — a `:normal` exit is
  # not a lost batch, so nothing else would report it either.
  defp deliver(content, plan) do
    Agent.deliver_internal(plan.parent_pid, "agents-batch", content, :notice)
  catch
    # `:noproc` is the only case where the aggregate is certainly gone: there is
    # no parent process left to hold it. A *timeout* is not that — the
    # `$gen_call` message stays in the parent's mailbox and the parent will still
    # enqueue the aggregate when it gets to it — so the warning must not claim
    # the batch was lost.
    :exit, {:noproc, _reason} ->
      Logger.warning("[batch] the parent is gone; the aggregate was not delivered")

    :exit, reason ->
      Logger.warning(
        "[batch] no confirmation that the aggregate was delivered " <>
          "(#{inspect(reason)}); it may still arrive"
      )
  end

  # ---- plumbing ----

  defp spawn_child(parent, opts) do
    case GenServer.call(parent, {:spawn_agent_request, self(), opts}, @call_timeout_ms) do
      {:ok, spawned_name} -> {:ok, spawned_name}
      {:error, reason} -> {:error, reason}
    end
  end

  # The parent's own tool asked for this stop, so it enqueues no notice for the
  # child (`Machine.Children`'s abandonment ruling) and this coordinator writes
  # the marker. A parent that has gone away mid-batch is not an error here.
  defp abandon(parent, name) do
    GenServer.call(parent, {:abandon_child, self(), name}, @call_timeout_ms)
  catch
    _, _ -> :ok
  end

  # Write `value` into slot `index` and drop `name` from the pending set.
  defp set_done(plan, index, value, name) do
    plan
    |> Map.update!(:results, &List.replace_at(&1, index, value))
    |> Map.put(:pending, Map.delete(plan.pending, name))
  end

  # How long to wait before the next deadline check: the soonest pending child's
  # deadline, or 0 if one has already passed.
  defp next_wait(%{pending: pending}) do
    now = System.monotonic_time(:millisecond)
    min_deadline = pending |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.min()
    max(0, min_deadline - now)
  end
end

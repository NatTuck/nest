defmodule NestWeb.AgentChannel.Pane do
  @moduledoc """
  The agent channel's pane handlers (issues #119 and #120).

  The pane is per **space**, not per agent: a client joined to any agent in the
  space sees the same decision queue and TODO lists, and every pane frame is
  broadcast on the space's pane topic. The handlers live here, rather than in
  `NestWeb.AgentChannel`, to keep that module within its file budget.

  ## Only a user action removes a decision

  `answer/2` and `drop/2` are user actions, so they are the only removals. An
  agent can append (`decisions-ask`) and mark in place
  (`decisions-obsolete`), never remove or reorder. A decision whose asking
  agent is gone or archived is marked `orphaned` — drop-only — and that mark
  reaches the client through the broadcast, never through a client-side guess.

  ## Delivery

  An answer is delivered as the human's own words (`Nest.Agents.chat/6` with
  `human?: true` and **no mode**), through the same path `chat:message` uses, so
  queueing and busy semantics are identical. Removal and delivery happen in this
  handler, in that order, so the transcript and the list cannot disagree: a
  decision that could not be delivered stays answerable, and one that was
  removed has its message on its way. Answers for the same asking agent ride one
  message; different agents get one message each.
  """

  require Logger

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Pane, as: Store
  alias Nest.Agents.Supervisor
  alias NestWeb.AgentChannel.Replies
  alias NestWeb.ErrorPayload

  # The statuses that cannot accept a message at all, shared with
  # `chat:message`'s check. A decision whose asking agent is in one of these is
  # *not* orphaned — the row exists and the user may retry — so it is reported
  # `failed` and left in the list.
  @broken_statuses Machine.blocked_phases()

  # A client cannot answer more decisions than the queue can hold; anything
  # beyond that is either a bug or an attempt to make one reply huge, and both
  # are refused rather than processed.
  @max_answers 100

  # ---- pane:sync ----

  @doc """
  The space's current pane payload, for a client that joined, reloaded, or
  missed a frame.
  """
  @spec sync(Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def sync(socket) do
    case authorize(socket) do
      :ok -> {:reply, {:ok, Store.payload(socket.assigns.space_id)}, socket}
      {:error, payload} -> {:reply, {:error, payload}, socket}
    end
  end

  # ---- decisions:answer ----

  @doc """
  Record the user's answers: remove each answered decision from the space's
  queue and deliver its answer to the agent that asked it.

  A decision whose asking agent is gone or archived is marked orphaned and
  reported, not delivered; one whose agent exists but is in a blocked status is
  reported `failed` and left answerable, so the user can retry.
  """
  @spec answer(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def answer(%{"answers" => answers}, socket) when is_list(answers) do
    case authorize(socket) do
      :ok -> answer_authorized(answers, socket)
      {:error, payload} -> {:reply, {:error, payload}, socket}
    end
  end

  def answer(_payload, socket), do: invalid(socket)

  defp answer_authorized(answers, socket) do
    case classify(socket.assigns.space_id, answers) do
      {:ok, classified} -> {:reply, {:ok, apply_answers(socket, classified)}, socket}
      :invalid -> invalid(socket)
    end
  end

  # ---- decisions:drop ----

  @doc """
  Remove decisions the user dropped. A question whose asking agent is alive is
  told with a runtime notice, so it stops waiting; an orphaned one has nobody to
  tell and is simply removed.
  """
  @spec drop(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def drop(%{"ids" => ids}, socket) when is_list(ids) do
    case authorize(socket) do
      :ok ->
        removed = Store.take(socket.assigns.space_id, Enum.filter(ids, &is_binary/1))
        Enum.each(removed, &notify_dropped(socket.assigns.space_id, &1))
        {:reply, :ok, socket}

      {:error, payload} ->
        {:reply, {:error, payload}, socket}
    end
  end

  def drop(_payload, socket), do: invalid(socket)

  # ---- decisions:explain ----

  @doc """
  Ask the agent that posed a decision to expand it. The decision stays open:
  this is a request for detail, not a resolution.
  """
  @spec explain(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def explain(%{"id" => id}, socket) when is_binary(id) do
    case authorize(socket) do
      :ok -> explain_authorized(socket, id)
      {:error, payload} -> {:reply, {:error, payload}, socket}
    end
  end

  def explain(_payload, socket), do: invalid(socket)

  defp explain_authorized(socket, id) do
    space_id = socket.assigns.space_id
    sender = socket.assigns.current_user.username

    case Enum.find(Store.decisions(space_id), &(&1.id == id)) do
      nil ->
        {:reply, {:error, %{"reason" => "decision_not_found"}}, socket}

      decision ->
        case deliver_explain(space_id, decision, sender) do
          :ok -> {:reply, :ok, socket}
          {:error, reason} -> {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
        end
    end
  end

  defp deliver_explain(space_id, decision, sender) do
    body = "Please explain #{inspect(decision.title)} in more detail."

    case Agents.get_info(space_id, decision.asked_by) do
      {:ok, %{status: status}} when status in @broken_statuses ->
        {:error, "agent_status_#{status}"}

      {:ok, _info} ->
        case Agents.chat(space_id, decision.asked_by, body, nil, sender, true) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      # Nobody to ask. The mark is what tells the pane this question is
      # drop-only now; it is not an error the user can act on.
      {:error, reason} ->
        Store.mark_orphaned(space_id, [decision.id], orphan_reason(reason))
        :ok
    end
  end

  # ---- Classification ----

  # One verdict per answered decision, resolved against a snapshot of the
  # queue and one agent lookup per distinct asking agent. Nothing is mutated
  # here: `apply_answers/2` takes the deliverable ones and marks the rest.
  defp classify(space_id, answers) do
    case parse_answers(answers) do
      {:ok, pairs} ->
        decisions = Map.new(Store.decisions(space_id), &{&1.id, &1})
        agents = agent_states(space_id, pairs, decisions)

        {:ok,
         Enum.map(pairs, fn {id, answer} ->
           {id, answer, verdict(Map.get(decisions, id), agents)}
         end)}

      :invalid ->
        :invalid
    end
  end

  defp parse_answers(answers) when length(answers) > @max_answers, do: :invalid

  defp parse_answers(answers) do
    answers
    |> Enum.reduce_while({:ok, []}, fn
      %{"id" => id, "answer" => answer}, {:ok, acc} when is_binary(id) and is_binary(answer) ->
        {:cont, {:ok, [{id, answer} | acc]}}

      _other, _acc ->
        {:halt, :invalid}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :invalid -> :invalid
    end
  end

  defp agent_states(space_id, pairs, decisions) do
    pairs
    |> Enum.map(fn {id, _answer} -> asked_by(decisions, id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(&{&1, Agents.get_info(space_id, &1)})
  end

  defp asked_by(decisions, id) do
    case Map.get(decisions, id) do
      %{asked_by: name} -> name
      nil -> nil
    end
  end

  defp verdict(nil, _agents), do: {:failed, "decision_not_found"}

  defp verdict(%{orphaned?: true} = decision, _agents) do
    {:orphaned, decision.orphaned_reason || orphan_reason(:not_found)}
  end

  defp verdict(%{asked_by: name} = decision, agents) do
    case Map.get(agents, name) do
      {:ok, %{status: status}} when status in @broken_statuses ->
        {:failed, "agent_status_#{status}"}

      {:ok, _info} ->
        {:deliver, decision}

      {:error, reason} when reason in [:not_found, :archived] ->
        {:orphaned, orphan_reason(reason)}

      {:error, reason} ->
        {:failed, failure_reason(reason)}
    end
  end

  defp orphan_reason(:archived), do: "the agent that asked it was archived"
  defp orphan_reason(_reason), do: "the agent that asked it is gone"

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason), do: inspect(reason)

  # ---- Applying answers ----

  defp apply_answers(socket, classified) do
    space_id = socket.assigns.space_id
    sender = socket.assigns.current_user.username
    answers = Map.new(for {id, answer, _verdict} <- classified, do: {id, answer})
    to_deliver = for {id, _answer, {:deliver, _decision}} <- classified, do: id

    # Removal first, then delivery: the ids that actually went are the ones
    # taken, so a decision another client resolved concurrently is neither
    # delivered nor reported twice.
    taken = Store.take(space_id, to_deliver)
    outcomes = deliver(space_id, taken, answers, sender)
    mark_orphaned(space_id, classified)

    %{
      "delivered" => for(id <- to_deliver, Map.get(outcomes, id) == :delivered, do: id),
      "orphaned" => orphaned_payload(classified),
      "failed" => failures(classified, outcomes)
    }
  end

  defp orphaned_payload(classified) do
    for {id, _answer, {:orphaned, reason}} <- classified,
        do: %{"id" => id, "reason" => reason}
  end

  defp deliver(space_id, taken, answers, sender) do
    taken
    |> Enum.group_by(& &1.asked_by)
    |> Enum.flat_map(fn {name, decisions} ->
      case deliver_answers(space_id, name, decisions, answers, sender) do
        :ok -> Enum.map(decisions, &{&1.id, :delivered})
        {:error, reason} -> Enum.map(decisions, &{&1.id, {:failed, failure_reason(reason)}})
      end
    end)
    |> Map.new()
  end

  defp deliver_answers(space_id, name, decisions, answers, sender) do
    body =
      "Decisions answered:\n" <>
        Enum.map_join(decisions, "\n", fn decision ->
          "- #{decision.title}: #{Map.fetch!(answers, decision.id)}"
        end)

    case Agents.chat(space_id, name, body, nil, sender, true) do
      :ok ->
        :ok

      # The agent resolved a moment ago; losing it between the check and the
      # cast is a race, not a normal path. The decision is already gone from
      # the queue, so the honest report is a failure the log explains.
      {:error, reason} ->
        Logger.warning(
          "pane answer for #{space_id}/#{name} was not delivered: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp mark_orphaned(space_id, classified) do
    classified
    |> Enum.flat_map(fn
      {id, _answer, {:orphaned, reason}} -> [{id, reason}]
      _other -> []
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.each(fn {reason, ids} -> Store.mark_orphaned(space_id, ids, reason) end)
  end

  defp failures(classified, outcomes) do
    Enum.flat_map(classified, fn {id, _answer, verdict} ->
      case failure(verdict, Map.get(outcomes, id)) do
        nil -> []
        reason -> [%{"id" => id, "reason" => reason}]
      end
    end)
  end

  defp failure({:failed, reason}, _outcome), do: reason
  defp failure(_verdict, {:failed, reason}), do: reason
  defp failure(_verdict, _outcome), do: nil

  # ---- Drop notices ----

  # Only a *live* asking agent is told; an orphaned question has nobody to tell.
  # A `:runtime` entry is the runtime speaking for itself — the user dropped the
  # question — so it renders as `nest runtime`, not as a human's words.
  defp notify_dropped(space_id, decision) do
    case Supervisor.get_running_agent(space_id, decision.asked_by) do
      {:ok, pid} ->
        _ =
          Agent.deliver_internal(
            pid,
            nil,
            "The user dropped your question #{inspect(decision.title)}. " <>
              "You do not need to wait for an answer.",
            :runtime
          )

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # ---- Authorization ----

  # The join authorized the client for the agent whose topic it is on. Every
  # pane call re-checks that the agent still resolves, so a pane frame never
  # outlives its socket's authority; the refusal is the same
  # `%{"reason" => ...}` map every other handler replies with.
  defp authorize(socket) do
    case Agents.get_info(socket.assigns.space_id, socket.assigns.name) do
      {:ok, _info} ->
        :ok

      {:error, reason} ->
        {:error, ErrorPayload.from_reason(Replies.chat_message_reason(reason))}
    end
  end

  defp invalid(socket), do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
end

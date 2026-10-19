defmodule Nest.Agents.Agent.Pane do
  # The caps are module attributes rather than literals in the prose below so
  # the moduledoc and the code that enforces them cannot drift.
  @max_decisions 50
  @max_todos 50
  @max_title 200
  @max_body 4_000
  @max_option 300
  @max_reason 500
  @max_todo_text 500
  @min_options 2
  @max_options 5
  @statuses ~w(pending in_progress done)

  @moduledoc """
  Per-space state for the right-hand pane: the decisions (questions) an agent
  asks the user (issue #119) and the TODO list each agent keeps (issue #120).

  ## Shape and lifetime

  The state is **the space's**, not an agent's: one entry per `space_id`,
  holding that space's decision queue and a map from agent name to that agent's
  TODO list. It is held **in memory only** — no table, no migration — so a BEAM
  restart empties every pane. That is accepted for v1: the pane is a working
  surface for a conversation in progress, not a record. The entry is also not
  removed when a space's last agent stops: there is no clean hook for "this
  space is now idle", and a decision may legitimately outlive the process that
  asked it (which is exactly what `orphaned` is for). It therefore lives until
  the BEAM restarts.

  ## Broadcasts

  Every mutation announces itself on the space's pane topic
  (`Nest.Agents.Agent.Broadcasts.pane/1`) with a `seq` that increases once per
  mutation, so a client can drop a frame that arrives out of order. The
  announcement carries no payload: a TODO list belongs to one agent and is
  capped per agent, so each subscriber builds its own frame with `payload/2`
  from **one** read, and the decisions and the `seq` in it always agree. The
  decision queue itself is small and bounded (see below), so a full list per
  frame is cheaper than the client-side reconciliation a delta protocol would
  need. `payload/2` — the `pane:sync` reply — returns the current state at the
  current `seq` and does **not** advance it: a sync is not a mutation, and
  advancing the counter without an announcement would make a client drop the
  next real frame.

  ## Append-only

  A decision is only ever **appended**. `mark_obsolete/4` marks it in place and
  `mark_orphaned/3` does the same; nothing an agent does removes or reorders
  one. Removal is a *user* action — answering or dropping, both in
  `NestWeb.AgentChannel.Pane` — because the pane's UI rule is that a rendered
  interactive element must not move or disappear except in response to the
  user.

  ## Bounds

  A runaway agent must not be able to grow the state or a frame without limit,
  so everything an agent can send is validated here: at most #{@max_decisions}
  decisions per space, at most #{@max_todos} TODO items **per agent**, and a
  length cap on every string (title, body, option, TODO text, reason). A refusal
  is returned as `{:error, message}` for the caller to hand to the model.

  The per-agent TODO cap is why a frame carries only the *viewer's* list
  (`payload/2`): the number of agents in a space is not bounded by anything
  here, so a frame with every agent's list would grow with it.

  ## Blocking

  This GenServer never blocks for an unknown amount of time. Every callback is
  bounded local work over lists this module caps, and it touches no database,
  no file and no other process — so a `GenServer.call/3` to it is ordinary
  synchronous communication, not a blocking hand-off.
  """

  use GenServer

  alias Nest.Agents.Agent.Broadcasts

  @name __MODULE__

  @typedoc """
  One question in the space's queue. `asked_by` is the agent name the answer
  goes back to, which is not necessarily the agent whose page the user is on.
  """
  @type decision :: %{
          id: String.t(),
          title: String.t(),
          body: String.t(),
          options: [String.t()],
          asked_by: String.t(),
          obsolete?: boolean(),
          obsolete_reason: String.t() | nil,
          orphaned?: boolean(),
          orphaned_reason: String.t() | nil
        }

  @typedoc "One item of an agent's TODO list."
  @type todo :: %{text: String.t(), status: String.t()}

  @type space_id :: integer()

  # ---- Client API ----

  @doc """
  The caps this module enforces, in one place.

  The tool schemas declare the same numbers (`maxLength`, `maxItems`), so a
  model reads the limit it will be refused on; keeping them here means the two
  cannot drift.
  """
  @spec caps() :: %{
          decisions: pos_integer(),
          todos: pos_integer(),
          title: pos_integer(),
          body: pos_integer(),
          option: pos_integer(),
          reason: pos_integer(),
          todo_text: pos_integer(),
          min_options: pos_integer(),
          max_options: pos_integer(),
          statuses: [String.t()]
        }
  def caps do
    %{
      decisions: @max_decisions,
      todos: @max_todos,
      title: @max_title,
      body: @max_body,
      option: @max_option,
      reason: @max_reason,
      todo_text: @max_todo_text,
      min_options: @min_options,
      max_options: @max_options,
      statuses: @statuses
    }
  end

  @doc "The registered name this GenServer runs under."
  @spec name() :: atom()
  def name, do: @name

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{id: @name, start: {__MODULE__, :start_link, []}, type: :worker}
  end

  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @doc """
  The pane payload **for one viewer**: the space's decision queue plus the
  TODO list of the agent named by `agent_name`. Does not broadcast and does not
  advance `seq`.

  The decision queue is the space's, but a TODO list is one agent's, and the
  list is capped per agent rather than per space — so a frame carrying every
  agent's list would grow with the number of agents in the space. The frame is
  therefore built per viewer, which is why the broadcast is a change
  notification and each channel asks for its own payload.
  """
  @spec payload(space_id(), String.t()) :: map()
  def payload(space_id, agent_name) do
    GenServer.call(@name, {:payload, space_id, agent_name})
  end

  @doc """
  Append a decision asked by `asked_by`. Returns the new decision's id, or a
  message explaining why the decision was refused (a bad field, or a full
  queue).
  """
  @spec ask(space_id(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def ask(space_id, asked_by, title, body, options) do
    GenServer.call(@name, {:ask, space_id, asked_by, title, body, options})
  end

  @doc "The space's decision queue, oldest first."
  @spec decisions(space_id()) :: [decision()]
  def decisions(space_id), do: GenServer.call(@name, {:decisions, space_id})

  @doc """
  Remove the decisions named by `ids` (a user action: answering or dropping)
  and return the ones actually removed, in queue order. Unknown ids are
  ignored; nothing is broadcast when nothing was removed.
  """
  @spec take(space_id(), [String.t()]) :: [decision()]
  def take(space_id, ids), do: GenServer.call(@name, {:take, space_id, ids})

  @doc """
  Mark a decision obsolete, in place, on behalf of `asked_by`. Never removes and
  never reorders it — dropping it stays the user's call.

  `asked_by` must be the agent that asked it: an agent may retire its own
  question, not a peer's. A mismatch is `{:error, :not_yours}`, checked here
  rather than by the caller so the check and the update are one operation.
  """
  @spec mark_obsolete(space_id(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :not_yours | String.t()}
  def mark_obsolete(space_id, id, reason, asked_by) do
    GenServer.call(@name, {:mark_obsolete, space_id, id, reason, asked_by})
  end

  @doc """
  Mark decisions orphaned — the agent that asked is gone or archived, so the
  question can only be dropped. Ids that are already orphaned are left alone.
  """
  @spec mark_orphaned(space_id(), [String.t()], String.t()) :: :ok
  def mark_orphaned(space_id, ids, reason) do
    GenServer.call(@name, {:mark_orphaned, space_id, ids, reason})
  end

  @doc """
  Replace this agent's TODO list. The opencode shape: no ids, no per-item
  update — the agent sends the whole list every time.
  """
  @spec write_todos(space_id(), String.t(), [map()]) :: :ok | {:error, String.t()}
  def write_todos(space_id, agent_name, items) do
    GenServer.call(@name, {:write_todos, space_id, agent_name, items})
  end

  @doc "This agent's TODO list, in the order it was written."
  @spec todos(space_id(), String.t()) :: [todo()]
  def todos(space_id, agent_name), do: GenServer.call(@name, {:todos, space_id, agent_name})

  # ---- Server callbacks ----

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:payload, space_id, agent_name}, _from, state) do
    {:reply, payload(space_id, entry(state, space_id), agent_name), state}
  end

  def handle_call({:ask, space_id, asked_by, title, body, options}, _from, state) do
    entry = entry(state, space_id)

    with :ok <- room(entry),
         {:ok, title} <- text(title, "title", @max_title),
         {:ok, body} <- text(body, "body", @max_body),
         {:ok, options} <- options(options) do
      id = "d#{entry.next_id}"

      decision = %{
        id: id,
        title: title,
        body: body,
        options: options,
        asked_by: asked_by,
        obsolete?: false,
        obsolete_reason: nil,
        orphaned?: false,
        orphaned_reason: nil
      }

      entry = %{entry | decisions: entry.decisions ++ [decision], next_id: entry.next_id + 1}
      {:reply, {:ok, id}, broadcast(state, space_id, entry)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decisions, space_id}, _from, state) do
    {:reply, entry(state, space_id).decisions, state}
  end

  def handle_call({:take, space_id, ids}, _from, state) do
    entry = entry(state, space_id)
    wanted = MapSet.new(ids)
    {removed, kept} = Enum.split_with(entry.decisions, &MapSet.member?(wanted, &1.id))

    if removed == [] do
      {:reply, [], state}
    else
      {:reply, removed, broadcast(state, space_id, %{entry | decisions: kept})}
    end
  end

  def handle_call({:mark_obsolete, space_id, id, reason, asked_by}, _from, state) do
    case text(reason, "reason", @max_reason) do
      {:ok, reason} -> reply_obsolete(space_id, id, reason, asked_by, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_orphaned, space_id, ids, reason}, _from, state) do
    before = entry(state, space_id)
    wanted = MapSet.new(ids)
    decisions = Enum.map(before.decisions, &maybe_orphan(&1, wanted, reason))

    if decisions == before.decisions do
      {:reply, :ok, state}
    else
      {:reply, :ok, broadcast(state, space_id, %{before | decisions: decisions})}
    end
  end

  def handle_call({:write_todos, space_id, agent_name, items}, _from, state) do
    case todo_items(items) do
      {:ok, todos} ->
        entry = put_todos(entry(state, space_id), agent_name, todos)
        {:reply, :ok, broadcast(state, space_id, entry)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:todos, space_id, agent_name}, _from, state) do
    {:reply, Map.get(entry(state, space_id).todos, agent_name, []), state}
  end

  # ---- Shaping ----

  defp entry(state, space_id), do: Map.get(state, space_id, new_entry())

  defp new_entry, do: %{decisions: [], todos: %{}, seq: 0, next_id: 1}

  # One mutation: advance the frame counter, announce the change, and keep the
  # entry. Every mutation goes through here, so `seq` is the number of frames
  # this space has emitted. The announcement carries no payload: the TODO half
  # is per viewer (see `payload/2`), so each channel asks for its own.
  defp broadcast(state, space_id, entry) do
    entry = %{entry | seq: entry.seq + 1}
    Broadcasts.pane(space_id)
    Map.put(state, space_id, entry)
  end

  defp payload(space_id, entry, agent_name) do
    %{
      "spaceId" => space_id,
      "decisions" => Enum.map(entry.decisions, &decision_payload/1),
      # One entry, keyed by the agent whose page this frame is for: the client
      # reads its list by name, and no other agent's list is on the wire.
      "todos" => %{agent_name => Enum.map(Map.get(entry.todos, agent_name, []), &todo_payload/1)},
      "seq" => entry.seq
    }
  end

  # Every key is present on every frame, `nil` included, so the client reads one
  # shape and a missing key never renders as "not obsolete" by accident.
  defp decision_payload(decision) do
    %{
      "id" => decision.id,
      "title" => decision.title,
      "body" => decision.body,
      "options" => decision.options,
      "askedBy" => decision.asked_by,
      "obsolete" => decision.obsolete?,
      "obsoleteReason" => decision.obsolete_reason,
      "orphaned" => decision.orphaned?,
      "orphanedReason" => decision.orphaned_reason
    }
  end

  defp todo_payload(todo), do: %{"text" => todo.text, "status" => todo.status}

  # ---- Decision updates ----

  defp reply_obsolete(space_id, id, reason, asked_by, state) do
    case update_decision(entry(state, space_id), id, asked_by, &obsolete(&1, reason)) do
      :not_found -> {:reply, {:error, :not_found}, state}
      :not_yours -> {:reply, {:error, :not_yours}, state}
      {:ok, entry} -> {:reply, :ok, broadcast(state, space_id, entry)}
    end
  end

  defp update_decision(entry, id, asked_by, fun) do
    case Enum.find_index(entry.decisions, &(&1.id == id)) do
      nil ->
        :not_found

      index ->
        decision = Enum.at(entry.decisions, index)

        if decision.asked_by == asked_by do
          {:ok, %{entry | decisions: List.update_at(entry.decisions, index, fun)}}
        else
          :not_yours
        end
    end
  end

  # Marks in place: the list's order and the decision's id are untouched, which
  # is what keeps a rendered accordion row where the user last saw it.
  defp obsolete(decision, reason) do
    %{decision | obsolete?: true, obsolete_reason: reason}
  end

  defp maybe_orphan(%{id: id, orphaned?: false} = decision, wanted, reason) do
    if MapSet.member?(wanted, id) do
      %{decision | orphaned?: true, orphaned_reason: reason}
    else
      decision
    end
  end

  defp maybe_orphan(decision, _wanted, _reason), do: decision

  defp put_todos(entry, agent_name, todos) do
    %{entry | todos: Map.put(entry.todos, agent_name, todos)}
  end

  # ---- Validation ----

  defp room(%{decisions: decisions}) when length(decisions) >= @max_decisions do
    {:error,
     "The user's decision queue is full (#{@max_decisions} open questions). " <>
       "Wait for the user to answer or drop some before asking more."}
  end

  defp room(_entry), do: :ok

  defp text(value, field, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "The #{field} must not be empty."}

      String.length(trimmed) > max ->
        {:error, "The #{field} must be at most #{max} characters."}

      true ->
        {:ok, trimmed}
    end
  end

  defp text(_value, field, _max), do: {:error, "The #{field} must be a string."}

  defp options(list) when is_list(list) and length(list) in @min_options..@max_options do
    Enum.reduce_while(list, {:ok, []}, fn option, {:ok, acc} ->
      case text(option, "option", @max_option) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp options(_list) do
    {:error, "Options must be a list of #{@min_options} to #{@max_options} strings."}
  end

  defp todo_items(items) when is_list(items) and length(items) <= @max_todos do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case todo_item(item) do
        {:ok, todo} -> {:cont, {:ok, acc ++ [todo]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp todo_items(_items) do
    {:error, "Items must be a list of at most #{@max_todos} TODO entries."}
  end

  defp todo_item(%{"text" => text, "status" => status}) when status in @statuses do
    with {:ok, text} <- text(text, "TODO text", @max_todo_text) do
      {:ok, %{text: text, status: status}}
    end
  end

  defp todo_item(%{"status" => status}) when status in @statuses do
    {:error, "Each TODO entry needs a text string."}
  end

  defp todo_item(%{"status" => status}) when is_binary(status) do
    {:error, "Unknown TODO status #{inspect(status)}; use one of #{Enum.join(@statuses, ", ")}."}
  end

  defp todo_item(_item) do
    {:error,
     "Each TODO entry must be an object with a text string and a status of " <>
       Enum.join(@statuses, ", ") <> "."}
  end
end

defmodule Nest.Agents.Agent.ChatTurnSupervisor do
  @moduledoc """
  DynamicSupervisor for `Nest.Agents.Agent.ChatTurn` children.

  One supervisor at the top level, used by all agents. Each
  ChatTurn is tied to its parent Agent's pid (passed in init
  args). A single in-flight ChatTurn per Agent is the norm;
  the supervisor is here so a child crash (e.g. a stray
  FunctionClauseError in the HTTP worker) doesn't take the
  supervisor down, and so the ChatTurn can be stopped /
  restarted cleanly by the Agent when the iteration ends.

  The ChatTurn is a `:temporary` restart — a crashed turn is
  not useful to restart (its message indices are already
  gone, its streaming_acc is half-built). The Agent's
  `chat_crashed` handler is the only signal the rest of the
  system needs; the supervisor's restart is just enough to
  let `start_chat_turn/3` succeed for the next turn.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 100)
  end

  @doc """
  Spawn a ChatTurn child for the given Agent. Returns
  `{:ok, pid}` on success or `{:error, reason}` if the
  supervisor is saturated.

  Used by `ChatPipeline.spawn_chat_turn/1` after the user
  message is appended to the Agent. The ChatTurn drives the
  iteration by querying the Agent for messages, calling the
  LLM via `Nest.LLM.Runner.request/2`, and dispatching
  tool calls. The Agent is the single source of truth for
  the messages list — the ChatTurn never mutates it
  directly, only via `GenServer.call({:append_message, _})`.
  """
  @spec start_chat_turn(pid(), map(), map()) :: DynamicSupervisor.on_start_child()
  def start_chat_turn(agent_pid, ctx, init_state) do
    spec = %{
      id: {__MODULE__, agent_pid, System.unique_integer([:positive])},
      start: {Nest.Agents.Agent.ChatTurn, :start_link, [{agent_pid, ctx, init_state}]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end

defmodule Nest.Agents.Agent.Machine.Phase do
  @moduledoc """
  Shared pure phase/working-set helpers for the machine transition table.

  `enter/4`, `enter_blocked/2`, and `clear_worker/1` are the only functions
  that write `phase:` on a machine; grouping them here (along with the
  entry/context helpers) keeps `Machine.Transitions` and
  `Machine.Compaction` within the file-length budget and makes the single
  writer obvious.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.User

  @doc "Enter a kind/phase with an optional in-flight worker kind."
  @spec enter(Machine.t(), Machine.kind(), Machine.phase(), :http | :tools | nil) :: Machine.t()
  def enter(m, kind, phase, worker_kind \\ nil) do
    Machine.validate!(%{
      m
      | kind: kind,
        phase: phase,
        work: %{
          m.work
          | worker_kind: worker_kind,
            worker_ref: nil,
            active_worker: nil,
            active_worker_kind: worker_kind
        }
    })
  end

  @doc "Enter an externally-unstuck blocked phase."
  @spec enter_blocked(Machine.t(), Machine.phase()) :: Machine.t()
  def enter_blocked(m, phase) do
    Machine.validate!(%{m | phase: phase, work: %{m.work | worker_kind: nil}})
  end

  @doc "Clear the in-flight worker bookkeeping."
  @spec clear_worker(Machine.t()) :: Machine.t()
  def clear_worker(m) do
    %{
      m
      | work: %{
          m.work
          | worker_kind: nil,
            worker_ref: nil,
            active_worker: nil,
            active_worker_kind: nil
        }
    }
  end

  @doc "The active message list from the turn context."
  @spec messages(Machine.t()) :: [term()]
  def messages(m), do: m.work.ctx.messages

  @doc "Merge fields into the turn context."
  @spec put_ctx(Machine.t(), keyword()) :: Machine.t()
  def put_ctx(m, changes) do
    %{m | work: %{m.work | ctx: Map.merge(m.work.ctx, Map.new(changes))}}
  end

  @doc "Normalize a held/start user entry to its `{:user, User.t()}` shape."
  @spec unwrap_user(term()) :: {:user, User.t()}
  def unwrap_user({:user, _} = user), do: user
  def unwrap_user(%User{} = user), do: {:user, user}
  def unwrap_user({:user_message, %User{} = user}), do: {:user, user}
  def unwrap_user({:user_message, {:user, _} = user}), do: user

  # Legacy held-message shape `{content, mode}` (pre-machine fixtures).
  def unwrap_user({content, mode}) when is_binary(content) and is_binary(mode) do
    Dispatch.build_user_message(content, mode)
  end

  @doc "Seed a turn's iteration/max-iteration bookkeeping from the entry."
  @spec init_turn(Machine.t(), Machine.entry() | nil) :: Machine.t()
  def init_turn(machine, entry) do
    work = machine.work

    %{
      machine
      | work: %{
          work
          | iteration: entry_iteration(entry),
            max_iterations: entry_max_iterations(entry),
            force_finalize: false
        }
    }
  end

  @doc false
  @spec entry_iteration(term()) :: non_neg_integer()
  def entry_iteration({_tag, _msg, n, _max}) when is_integer(n), do: n
  def entry_iteration(_), do: 0

  @doc false
  @spec entry_max_iterations(term()) :: pos_integer()
  def entry_max_iterations({_tag, _msg, _n, m}) when is_integer(m), do: m
  def entry_max_iterations(_), do: Config.configured_max_tool_iterations()
end

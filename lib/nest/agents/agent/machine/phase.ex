defmodule Nest.Agents.Agent.Machine.Phase do
  @moduledoc """
  Shared pure phase/working-set helpers for the machine transition table.

  `enter/4`, `enter_blocked/2`, and `clear_worker/1` are the only functions
  that write `phase:` on a machine; grouping them here (along with the
  entry/context helpers) keeps `Machine.Transitions` and
  `Machine.Compaction` within the file-length budget and makes the single
  writer obvious.

  `enter/4` is also the turn boundary, so it is where the turn-scoped
  `work.focus` is dropped: entering a chat turn, or entering any `:idle`
  phase, ends the compaction turn the focus was staged for, so the
  operator's guidance cannot leak into a later *automatic* compaction.
  Entering a `:compaction` turn leaves it untouched, and
  `enter_blocked/2` deliberately preserves it so a `:compaction_failed`
  retry re-renders the same guidance.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.User

  require Logger

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
            active_worker_kind: worker_kind,
            focus: turn_focus(kind, phase, m.work.focus)
        }
    })
  end

  # `focus` is turn-scoped: it exists only for the compaction turn it was
  # staged for. Entering a chat turn — or any `:idle` phase — ends that
  # turn, so the operator's guidance must not survive into a later
  # *automatic* compaction (`Transitions.start_chat/3`,
  # `Response.finalize_or_defer/4`, `:workspace_notice`), which would
  # silently apply a stale focus to a summary nobody asked for.
  #
  # Both clauses are load-bearing:
  #   * `kind == :chat` covers `Compaction.resume/1` →
  #     `resume_machine/2`, which enters `:generating` directly from
  #     `:committing` and never passes through `:idle`;
  #   * `phase == :idle` covers a stop during a compaction (`{:stop, _}`
  #     → `:stopping` keeps kind `:compaction`, then `stop_timer` →
  #     `enter(m, m.kind, :idle)`) and any other route back to idle with a
  #     stale focus.
  #
  # Leaving a `:compaction` turn untouched is what keeps `retry_compaction`
  # (from `:compaction_failed`) re-rendering the SAME focus.
  defp turn_focus(:chat, _phase, _focus), do: nil
  defp turn_focus(_kind, :idle, _focus), do: nil
  defp turn_focus(_kind, _phase, focus), do: focus

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

  @doc """
  The `%User{}` parked on `pending_user_message`, or nil.
  """
  @spec held_user(Machine.t()) :: User.t() | nil
  def held_user(%{pending_user_message: nil}), do: nil

  def held_user(%{pending_user_message: entry}) do
    # Normalized through `unwrap_user/1` — the single held-shape table (the
    # drain path parks `{:user_message, {:user, user}}`, a chat request parks
    # `{:user_message, user}`, and the legacy `{content, mode}` fixture shape
    # is accepted too). A value it cannot unwrap is logged and treated as
    # nothing held: a declared event never raises, and a drop is never silent.
    #
    # Lives here rather than in `Machine.Transitions` because two transition
    # modules need it: the `:loop_ack` loop breaker and `Compaction.do_stage/2`'s
    # `:reserve_exhausted` give-up path.
    case unwrap_user(entry) do
      {:user, %User{} = user} -> user
      _ -> nil
    end
  rescue
    FunctionClauseError ->
      Logger.warning("[turn] unrecognized pending_user_message: #{inspect(entry)}")
      nil
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

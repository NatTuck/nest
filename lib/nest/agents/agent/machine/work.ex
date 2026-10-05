defmodule Nest.Agents.Agent.Machine.Work do
  @moduledoc """
  The machine's turn-scoped working set.

  Grouped out of `Nest.Agents.Agent.Machine` so the machine struct stays
  within the struct-field cap. Everything here is *internal* working
  memory: it is not observable (the observable status derives from
  `kind`/`phase` via `Machine.status_for/1`) and it exists only while a
  turn is in flight.

  `ctx` is the read-only per-turn snapshot (client config, tools, caps,
  context limit, the request message list). `worker_ref` is the
  `make_ref/0` token handed to the active HTTP/tool worker; worker
  results are applied only when their ref and phase match the live turn.
  `preflight` caches the pending tool batch while its fit check runs.
  """

  defstruct ctx: nil,
            iteration: 0,
            max_iterations: 0,
            force_finalize: false,
            active_worker: nil,
            active_worker_kind: nil,
            worker_ref: nil,
            worker_kind: nil,
            active_message_index: 0,
            pending_notice: nil,
            preflight: nil

  @type t :: %__MODULE__{
          ctx: map() | nil,
          iteration: non_neg_integer(),
          max_iterations: non_neg_integer(),
          force_finalize: boolean(),
          active_worker: pid() | nil,
          active_worker_kind: :http | :tools | nil,
          worker_ref: reference() | nil,
          worker_kind: :http | :tools | nil,
          active_message_index: non_neg_integer(),
          pending_notice: String.t() | nil,
          preflight: map() | nil
        }

  @doc "Reset the working set."
  @spec new() :: t()
  def new, do: %__MODULE__{}
end

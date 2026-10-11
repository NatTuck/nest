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
  `backgrounded` holds the batches that were moved out of
  `worker_ref`/`active_worker` when a message arrived mid-batch (issue
  #36), keyed by the batch's ref: `%{ref => %{pid: pid, calls: count}}`.
  The turn keeps working while the batch runs in the background, so the
  entry — not `worker_ref` — is what its eventual result or worker death
  is routed on; `calls` is how many tool calls the batch answered, which
  is the count the stop's cancellation record reports, and the calls
  themselves are not kept, because the synthetic result has already
  answered them in the transcript. `preflight` caches the pending
  tool batch while its fit check runs. `focus` is the optional operator
  guidance for the summary
  (the `context-compact` tool's `focus` arg or `/compact <focus>`); it is
  rendered into the compaction request suffix. It is *turn-scoped*: it is
  cleared when the compaction turn ends (a chat turn or idle begins), so a
  stale focus cannot leak into a later *automatic* compaction.
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
            preflight: nil,
            # Batches moved to the background when a message arrived
            # mid-batch (issue #36): `%{ref => %{pid: pid, calls: count}}`.
            # The ref key is the batch's `worker_ref`; the entry is what its
            # late result or worker death is routed on, and `calls` is the
            # number of calls the synthetic result answered.
            backgrounded: %{},
            # Turn-scoped: `Machine.Phase.enter/4` clears it when the
            # compaction turn ends (a chat turn or idle begins).
            focus: nil

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
          preflight: map() | nil,
          backgrounded: %{reference() => %{pid: pid(), calls: pos_integer()}},
          focus: String.t() | nil
        }

  @doc "Reset the working set."
  @spec new() :: t()
  def new, do: %__MODULE__{}
end

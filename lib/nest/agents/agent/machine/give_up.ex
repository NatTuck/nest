defmodule Nest.Agents.Agent.Machine.GiveUp do
  @moduledoc """
  The reply give-up (issue #31 §1.6).

  A turn that ends while the agent still owes a peer a reply cannot keep
  working, so the runtime gives up on that reply: it tells each requester that
  no answer is coming — as a `:notice`, so the requester reads the runtime
  speaking and never the owing agent's own words (decision 9) — and then
  discharges the debt.

  That is one executor action, `{:give_up_replies, reason}`. It is computed by
  the resting funnel (`Machine.Phase.rest/4` and `Phase.block/4`) and by
  `Turn.quarantine!/2`, which owns its failure action list. The funnel is the
  point: a resting transition *cannot* skip the give-up, because the funnel is
  the only door to a resting phase, and a machine that owes nothing emits no
  action at all, so a debt-free rest is byte-for-byte what it was.

  `settle/3`'s old split — the transition entered the phase and the caller
  remembered to wrap its actions — is what the funnel replaces; the ordering it
  protected (the give-up *before* any `{:drain_inbox}`) now lives in
  `Phase.rest/4`.

  ## The audited sites

  Every site that rests passes one of the reasons below. `GuardTest` parses the
  sources (`Code.string_to_quoted!/1`) and fails when the reasons it finds on
  `Phase.rest/4` / `Phase.block/4` calls disagree with `audit/0` — the same rows,
  as data — or when a row is missing from this table. The matcher keys on the
  literal `Phase.` spelling, so a site that reaches the funnel through an alias
  (`alias …Phase, as: Funnel`) or through `apply/3` is invisible to it — still
  the same funnel, so the give-up still happens, but the table can drift without
  the guard noticing. Add a row, and the reason you pass, when you add one.

  | reason | sites | why the site rests |
  | --- | --- | --- |
  | `:loop_breaker` | 1 | the loop breaker gives up on compacting and settles the turn |
  | `:blocked` | 1 | an explicit `{:blocked, phase, _}` entry |
  | `:unblocked` | 1 | the operator unstuck a blocked agent |
  | `:stopped` | 2 | a stop finished, or its worker was killed |
  | `:workspace_notice` | 3 | a workspace notice landed but could not be delivered into a turn |
  | `:llm_error` | 1 | the stream errored |
  | `:interrupted_tool` | 1 | a tool worker died with nothing to repair |
  | `:turn_failed` | 1 | the turn crashed |
  | `:cannot_compact` | 1 | nothing fits and no compaction can help, so the agent blocks |
  | `:empty_assistant` | 1 | the model returned no content |
  | `:no_reminder` | 1 | a final reply that fits, once the gate can no longer remind |
  | `:compaction_loop` | 1 | consecutive compactions hit the cap |
  | `:system_oversized` | 1 | the system prompt alone is too big |
  | `:reserve_exhausted` | 3 | the reserve cannot hold the compaction: a held message, a queued batch, or nothing |
  | `:compaction_failed` | 2 | the compaction failed with nothing it can retry in place |
  | `:compaction_carry` | 1 | a reply carried across a compaction rests (the gate's fallback) |
  | `:resume` | 1 | the resume has nothing left to resume |
  | `:quarantine` | 1 | an undeclared turn event |
  | `:startup` | 2 | a restored agent comes up blocked; a fresh machine owes nothing, so this emits no action |

  ## Refusals

  Delivering a notice can fail (the requester is gone, its inbox is full, its
  process is blocked). That is a refusal, not a silent drop: the executor's
  `Turn.GiveUpDelivery` logs it and broadcasts a `chat:notification`, and
  `failure_reason/1` words the part the operator sees. The debt is discharged
  either way — the runtime has stopped waiting for that answer.
  """

  # The rows of the table above, as data: the reason each resting site passes to
  # `Machine.Phase.rest/4` / `Phase.block/4`, how many sites pass it, and why.
  # `GuardTest` checks this against the sources *and* against the table, so the
  # three cannot disagree.
  @audit [
    %{
      reason: :loop_breaker,
      sites: 1,
      why: "the loop breaker gives up on compacting and settles the turn"
    },
    %{reason: :blocked, sites: 1, why: "an explicit `{:blocked, phase, _}` entry"},
    %{reason: :unblocked, sites: 1, why: "the operator unstuck a blocked agent"},
    %{reason: :stopped, sites: 2, why: "a stop finished, or its worker was killed"},
    %{
      reason: :workspace_notice,
      sites: 3,
      why: "a workspace notice landed but could not be delivered into a turn"
    },
    %{reason: :llm_error, sites: 1, why: "the stream errored"},
    %{reason: :interrupted_tool, sites: 1, why: "a tool worker died with nothing to repair"},
    %{reason: :turn_failed, sites: 1, why: "the turn crashed"},
    %{
      reason: :cannot_compact,
      sites: 1,
      why: "nothing fits and no compaction can help, so the agent blocks"
    },
    %{reason: :empty_assistant, sites: 1, why: "the model returned no content"},
    %{
      reason: :no_reminder,
      sites: 1,
      why: "a final reply that fits, once the gate can no longer remind"
    },
    %{reason: :compaction_loop, sites: 1, why: "consecutive compactions hit the cap"},
    %{reason: :system_oversized, sites: 1, why: "the system prompt alone is too big"},
    %{
      reason: :reserve_exhausted,
      sites: 3,
      why: "the reserve cannot hold the compaction: a held message, a queued batch, or nothing"
    },
    %{
      reason: :compaction_failed,
      sites: 2,
      why: "the compaction failed with nothing it can retry in place"
    },
    %{
      reason: :compaction_carry,
      sites: 1,
      why: "a reply carried across a compaction rests (the gate's fallback)"
    },
    %{reason: :resume, sites: 1, why: "the resume has nothing left to resume"},
    %{reason: :quarantine, sites: 1, why: "an undeclared turn event"},
    %{
      reason: :startup,
      sites: 2,
      why:
        "a restored agent comes up blocked; a fresh machine owes nothing, so this emits no action"
    }
  ]

  alias Nest.Agents.Agent.Machine

  @doc """
  The give-up action for `machine`, or `[]` when it owes nothing.

  The resting funnel is the only caller (`Phase.rest/4` and `Phase.block/4`;
  `Turn.quarantine!/2` rests through `Phase.rest/4` too, so it does not build an
  action list of its own). `reason` names the site for the log line a refused
  notice writes, so the server log says why the runtime gave up and not merely
  that it did.
  """
  @spec actions(Machine.t(), atom()) :: [Machine.action()]
  def actions(%Machine{owed_replies: owed}, _reason) when map_size(owed) == 0, do: []
  def actions(%Machine{}, reason), do: [{:give_up_replies, reason}]

  @doc "The resting-site audit (see the moduledoc). Checked by `GuardTest`."
  @spec audit() :: [%{reason: atom(), sites: pos_integer(), why: String.t()}]
  def audit, do: @audit

  @doc """
  Human-readable form of a refused give-up, for the notification banner.
  """
  @spec failure_reason(term()) :: String.t()
  def failure_reason(:inbox_full), do: "the agent's inbox is full"
  def failure_reason({:status, status}), do: "the agent is in a #{status} state"
  def failure_reason(reason), do: inspect(reason)

  @doc """
  The runtime's notice to one requester, about the agent that did not answer.

  It names that agent and quotes nothing else (decision 4's instinct applied to
  the give-up too): the requester already has the query, and the runtime is
  reporting a fact about a peer, not speaking for it.
  """
  @spec notice_text(String.t()) :: String.t()
  def notice_text(owes) do
    "Runtime notice: agent \"#{owes}\" did not reply to the query you sent it, " <>
      "and the runtime gave up waiting for that answer."
  end
end

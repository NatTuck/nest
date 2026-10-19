defmodule Nest.Agents.Agent.NoticeDelivery do
  @moduledoc """
  What a settle did with a runtime notice pair.

  A notice is a user/assistant pair the runtime appends to the transcript: the
  space's environment changing (`Nest.Agents.Agent.WorkspaceHandler`) or the
  agent's model changing (`Nest.Agents.Agent.ModelHandler`). Both are settled as
  one machine event, and both can end in three different ways — none of which is
  readable from the machine's status:

    * `:appended` — the pair is in the transcript now. The `:fits` arm appends it
      and *then* runs `{:drain_inbox}`, and a drain can block after the pair is
      in, so asking the status alone would report a failure for a notice the
      agent has — and the caller would announce the same pair again;
    * `:deferred` — a compaction is carrying it and will append it when the
      commit lands. The notice rides that compaction's **entry**
      (`Nest.Agents.Agent.Machine.Compaction.stage/3`), which is the only place a
      notice can be in flight from: a failed staging, a failed commit or any
      route out of the turn drops the entry and the notice with it;
    * `{:error, status}` — the settle did not deliver the pair and nothing is in
      flight to deliver it later. `status` says where the machine ended up: a
      blocked phase (the conversation cannot hold the pair, or the compaction it
      would need could not start) or `:idle` (the compaction could not be staged
      at all, so the turn rested).

  The transcript is asked directly rather than the status, because the transcript
  is the record of what happened to the *pair*.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Messages.Part

  @typedoc """
  What became of the pair. Only `:appended` means the transcript has it and only
  `:deferred` means something is in flight to add it; everything else that is not
  `:appended` means the agent does not have it.
  """
  @type outcome :: :appended | :deferred | {:error, atom()}

  @doc """
  Classify a settle that was asked to deliver a notice whose user row's text is
  `text`.

  `before` is the state the settle started from and `settled` the state it
  produced; only the rows it added are considered, so a pair from an earlier
  change cannot be mistaken for this one. `text` must be built with the mode the
  *transition* saw (`before.live.mode`) — that is the mode the pair's header
  carries, and a drain inside the settle may change the mode after the append.

  A caveat worth stating, because it decides what the call sites' tests can pin:
  at those call sites the *only* observable that separates `:appended` from a
  failed delivery is the absence of the caller's `Logger.warning`, and
  `SMELLS.md` forbids asserting the absence of a log line (a capture is global,
  so the assertion flakes while testing nothing). The append itself is what the
  tests assert — the pair's text in the transcript — and this arm is pinned on its
  inputs instead (`test/nest/agents/agent/notice_delivery_test.exs`).
  """
  @spec outcome(Agent.t(), Agent.t(), String.t()) :: outcome()
  def outcome(before, settled, text) do
    cond do
      appended?(before, settled, text) -> :appended
      staged?(settled.live.machine) -> :deferred
      true -> {:error, Machine.status_for(settled.live.machine)}
    end
  end

  # The notice a compaction staged for itself: on its entry, which is the only
  # place a notice can be in flight from.
  defp staged?(%Machine{entry: {:compaction, _carried, notice}}), do: is_map(notice)
  defp staged?(%Machine{}), do: false

  defp appended?(before, settled, text) do
    settled.chat_state.messages
    |> Enum.drop(length(before.chat_state.messages))
    |> Enum.any?(fn
      {:user, %{parts: parts}} -> Enum.any?(parts, &match?(%Part.Text{text: ^text}, &1))
      _other -> false
    end)
  end
end

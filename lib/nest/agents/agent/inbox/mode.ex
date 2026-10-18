defmodule Nest.Agents.Agent.Inbox.Mode do
  @moduledoc """
  The mode a delivered batch asks the recipient to run under.

  A mode rides a *message*: the human's own request on a user message, and a
  peer's `set_mode` on an agent message — which is what makes the change and the
  instruction that depends on it land together. This is the reading half of that:
  which entry's mode a drain applies.

  There is no writing half. A mode that arrives this way is applied at the drain
  and written down by `Nest.Agents.Agent.Turn.keep_mode/2`; nothing announces it,
  because the message that carried it states it (its header's mode clause, or the
  peer header).

  Extracted from `Nest.Agents.Agent.Inbox` because the mode is a property of the
  *batch* rather than of the queue, and because the queue module is at credo's
  file-length cap.
  """

  alias Nest.Agents.Agent.Inbox

  @doc """
  The mode a drain batch runs in, or `nil` when it carries none.

  The winner is the most recent entry that names a mode. A batch is either a lone
  human message or a run of leading peer entries (`Inbox.batch/1`), so there is
  at most one human entry and the ordering is unambiguous.

  The winner is the *requested* mode; the executor's drain resolves it against the
  modes this build has (`Nest.Modes.valid?/1`) before storing it, exactly as an
  idle chat turn resolves its request.
  """
  @spec drain_mode([Inbox.entry()]) :: String.t() | nil
  def drain_mode(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{mode: mode} when is_binary(mode) -> mode
      _ -> nil
    end)
  end
end

defmodule Nest.Agents.Agent.Inbox.Mode do
  @moduledoc """
  The mode change a delivered batch carries.

  A mode rides a *message*: the human's own request on a user message, and a
  peer's `set_mode` on an agent message — which is what makes the change and the
  instruction that depends on it land together. This is the reading half of that:
  which entry's mode a drain applies, and who asked, so the announcement can name
  them.

  Extracted from `Nest.Agents.Agent.Inbox` because the mode is a property of the
  *batch* rather than of the queue, and because the queue module is at credo's
  file-length cap.
  """

  alias Nest.Agents.Agent.Inbox

  @typedoc """
  The change a batch carries: the requested mode, and who asked.
  """
  @type change :: %{mode: String.t(), actor: :human | {:agent, String.t()}}

  @doc """
  The mode change a drain batch carries, or `nil` when it carries none.

  The winner is the most recent entry that names a mode. A batch is either a lone
  human message or a run of leading peer entries (`Inbox.batch/1`), so there is
  at most one human entry and the ordering is unambiguous.

  The winner is the *requested* mode; the executor's drain resolves it against the
  modes this build has (`Nest.Modes.valid?/1`) before storing it, exactly as an
  idle chat turn resolves its request.
  """
  @spec drain_mode_change([Inbox.entry()]) :: change() | nil
  def drain_mode_change(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{mode: mode} = entry when is_binary(mode) -> %{mode: mode, actor: actor_of(entry)}
      _ -> nil
    end)
  end

  @doc """
  The mode a drain batch runs in, or `nil` when it carries none. The mode half of
  `drain_mode_change/1`, for callers that only need the value.
  """
  @spec drain_mode([Inbox.entry()]) :: String.t() | nil
  def drain_mode(entries) do
    case drain_mode_change(entries) do
      nil -> nil
      %{mode: mode} -> mode
    end
  end

  # `human?` is the flag that says a prompt was the human's own words (a spawn's
  # `query` kickoff is also a `:user` entry and is not), so it is what tells the
  # human's own mode selection from a peer's `set_mode`.
  defp actor_of(%{human?: true}), do: :human
  defp actor_of(%{from: from}) when is_binary(from) and from != "", do: {:agent, from}
  defp actor_of(_entry), do: :human
end

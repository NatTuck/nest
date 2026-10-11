defmodule Nest.Agents.Agent.Inbox.Delivery do
  @moduledoc """
  The delivery identity and consume semantics of a queued inbox entry
  (issue #62), split out of `Nest.Agents.Agent.Inbox` to keep that module
  under the credo line cap.

  An entry's `id` is a per-delivery identity: it rides the `chat:inbox` wire,
  names the over-cap offload file (`agent-inbox-<id>.txt`), and is what
  `agents-last-message` returns, so a caller can recognise a copy it already
  has. A fetch marks its entry `retrieved`; `Nest.Agents.Agent.Inbox.batch/1`
  skips a retrieved entry and `consume/2` drops it, so the turn-boundary drain
  cannot deliver a body the caller already pulled.
  """

  @doc """
  The opaque per-delivery id. A random token: the id is a delivery identity,
  not a sequence, and nothing needs to sort or derive it.
  """
  @spec new_id() :: String.t()
  def new_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  @doc """
  The id the offload file is named after: the batch's first entry. The batch
  is a FIFO prefix (`Inbox.batch/1`), so the first entry identifies it and the
  file the pointer names is traceable to a delivery the caller can recognise.
  """
  @spec batch_id([map()]) :: String.t()
  def batch_id([%{id: id} | _rest]), do: id
  def batch_id(_entries), do: new_id()

  @doc """
  True when an `agents-last-message` fetch already took this entry's body.
  Total over a hand-built entry (the drain and the wire both call it).
  """
  @spec retrieved?(map()) :: boolean()
  def retrieved?(%{retrieved: true}), do: true
  def retrieved?(_entry), do: false

  @doc """
  The entries a drain consumes: the delivered `batch` plus every entry an
  `agents-last-message` fetch already retrieved. A retrieved entry is never
  delivered — `Inbox.batch/1` skipped it — so the consume must drop it too, or
  it would sit in the queue forever.
  """
  @spec consume([map()], [map()]) :: [map()]
  def consume(entries, batch) do
    Enum.reject(entries, &(&1 in batch or retrieved?(&1)))
  end

  @doc """
  The newest pending entry a caller may fetch for `name`: the last entry whose
  `from` is `name` and which is not a human message. Returns the entry list
  with that entry marked retrieved, and the entry itself (or `nil`).

  A human message is never fetchable: `agents-last-message` is for a peer's or
  child's delivery, and a `:user` entry is the human speaking, which the caller
  must not be able to consume out from under the drain.
  """
  @spec take_last([map()], String.t()) :: {[map()], map() | nil}
  def take_last(entries, name) when is_binary(name) do
    case last_fetchable_index(entries, name) do
      nil ->
        {entries, nil}

      i ->
        entry = Enum.at(entries, i)
        {List.replace_at(entries, i, %{entry | retrieved: true}), entry}
    end
  end

  def take_last(entries, _name), do: {entries, nil}

  defp last_fetchable_index(entries, name) do
    entries
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{from: ^name, kind: kind} = entry, i}, acc when kind != :user ->
        if retrieved?(entry), do: acc, else: i

      {_other, _i}, acc ->
        acc
    end)
  end
end

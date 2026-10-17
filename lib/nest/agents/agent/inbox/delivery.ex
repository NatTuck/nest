defmodule Nest.Agents.Agent.Inbox.Delivery do
  @moduledoc """
  The delivery identity and consume semantics of a queued inbox entry,
  split out of `Nest.Agents.Agent.Inbox` to keep that module under the
  credo line cap.

  An entry's `id` is a per-delivery identity: it rides the `chat:inbox` wire
  (it is what a removal frame names an entry by) and it names the over-cap
  offload file (`agent-inbox-<id>.txt`). It is a random token rather than a
  sequence, because nothing needs to sort or derive it.
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
  The entries a drain consumes: exactly the delivered `batch`, and nothing
  else. Anything the peek did not deliver stays queued.
  """
  @spec consume([map()], [map()]) :: [map()]
  def consume(entries, batch), do: Enum.reject(entries, &(&1 in batch))
end

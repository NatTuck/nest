defmodule NestWeb.LobbyChannel.ProbeCache do
  @moduledoc """
  Multi-modal probe-cache `handle_in` handlers for the LobbyChannel:
  two admin-only events over one cache, extracted as a single-purpose
  module with its own tests — not to shorten the parent module, which
  is under the credo 500-line cap with or without them.

  Pure functions over `(payload, socket)` — each returns the
  `{:reply, reply, socket}` tuple `handle_in/3` is expected to.

  ## Permission rules

  Both events are admin-only: the cache file is server-level state,
  like `local.toml`, and clearing it costs every opted-in provider a
  fresh probe of every model on its next scan.

    * `probe_cache_stats` — read the entry count, the age of the oldest
      entry, and the file path, so the UI can show what a clear would
      destroy before it is clicked.
    * `clear_probe_cache` — empty the cache, then push the resulting
      stats to every session on the topic (each open providers page
      renders the same state) and reply with them.
  """

  alias Nest.LLM.MultimodalCache
  alias NestWeb.LobbyChannel.Authz

  @doc """
  Reply with the current probe-cache stats. Admin-only.
  """
  @spec stats(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def stats(_payload, socket),
    do: authorized(socket, fn -> {:ok, %{"stats" => MultimodalCache.stats()}} end)

  @doc """
  Empty the probe cache, broadcast the resulting stats to the topic, and
  reply with them. Admin-only, and idempotent: clearing an empty cache
  is the same no-op as clearing a full one.

  A scan already in flight is not touched — a verdict it settles on
  afterwards is written normally — so this means "forget what we knew
  before now", not "cancel this scan".
  """
  @spec clear(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def clear(_payload, socket) do
    authorized(socket, fn ->
      MultimodalCache.clear()
      stats = MultimodalCache.stats()
      Phoenix.Channel.broadcast(socket, "probe_cache_stats", %{stats: stats})
      {:ok, %{"stats" => stats}}
    end)
  end

  defp authorized(socket, reply_fun) do
    case Authz.authorize_admin(socket.assigns.current_user) do
      {:ok, :admin} -> {:reply, reply_fun.(), socket}
      {:error, _reason} -> {:reply, {:error, %{"reason" => "forbidden"}}, socket}
    end
  end
end

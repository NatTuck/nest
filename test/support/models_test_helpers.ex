defmodule Nest.Test.ModelsTestHelpers do
  @moduledoc """
  Test helpers for synchronizing on `Nest.Models` refreshes.

  `Nest.Models` does its HTTP I/O in a separate `Task.Supervisor`
  worker — the GenServer's mailbox returns from a `refresh/0` cast
  before the scan finishes. Tests that depend on the cache being
  populated (specifically tests that assert on auto-discovered
  models) need to wait for the next `{:models_updated, payload}`
  PubSub broadcast before reading `Models.list/0`.

  Tests that only use static-config models don't need this helper
  — `static_config.models` is populated synchronously by `init/1`
  and is returned by `Models.list/0` even while a scan is in flight.
  """

  alias Nest.Models

  @doc """
  Wait for the next `{:models_updated, _}` broadcast on the
  `"models"` PubSub topic. Triggers a fresh scan via
  `Models.refresh/0` first so the broadcast is guaranteed to fire
  (unless a scan was already in flight, in which case the next
  broadcast after subscribe is the one we wait for).

  Returns `:ok` on broadcast, `:timeout` if no broadcast arrives
  within `timeout_ms`. Does not subscribe the calling pid
  permanently — unsubscribes before returning.

  ## Examples

      ModelsTestHelpers.await_models_refresh()
      models = Models.list()
  """
  @spec await_models_refresh(pos_integer()) :: :ok | :timeout
  def await_models_refresh(timeout_ms \\ 5_000) do
    Phoenix.PubSub.subscribe(Nest.PubSub, "models")
    Models.refresh()

    receive do
      {:models_updated, _} -> :ok
    after
      timeout_ms -> :timeout
    end
    |> tap(fn _ -> Phoenix.PubSub.unsubscribe(Nest.PubSub, "models") end)
  end
end

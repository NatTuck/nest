defmodule Nest.Models.ContextLimits do
  @moduledoc """
  The published context-limit cache: one public ETS row holding the
  whole `context_limits` map.

  Published to a public ETS table so readers never touch the
  `Nest.Models` process: `Agent.init/1` resolves a context limit on
  every start, and `DynamicSupervisor.start_child/2` runs that `init/1`
  inside the supervisor's own `handle_call`, so a `GenServer.call` here
  put a second single process in the path of every concurrent start.
  One row — the whole `context_limits` map, rewritten whenever it
  changes (`Nest.Models.init/1`, `Nest.Models.finalize_scan/1`) — so
  reads are lock-free and see the old or the new map, never a partial
  one.

  The table is created lazily by the first `publish/1`, so it is owned
  by whichever process publishes first — in this tree the `Nest.Models`
  GenServer — and dies with it.
  """

  @limits_table :nest_models_context_limits

  @doc """
  Publish `limits` (the whole `context_limits` map) as the table's
  contents, creating the table when it does not exist yet.
  """
  @spec publish(map()) :: :ok
  def publish(limits) do
    if :ets.whereis(@limits_table) == :undefined do
      :ets.new(@limits_table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ets.insert(@limits_table, {:limits, limits})
    :ok
  end

  @doc """
  Look up the published `{source, limit}` for `{provider, model_id}`.

  `{:ok, nil}` means the table is published and has no entry for the
  pair. `:unavailable` means the table is gone (the `Nest.Models`
  server is not running, or is restarting) — the only case a caller
  still has to answer with a `GenServer.call`, which raises `:noproc`
  then, exactly as it did before this table existed.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, {term(), pos_integer()} | nil} | :unavailable
  def lookup(provider, model_id) do
    if :ets.whereis(@limits_table) == :undefined do
      :unavailable
    else
      case :ets.lookup(@limits_table, :limits) do
        [{:limits, limits}] -> {:ok, get_in(limits, [provider, model_id])}
        [] -> :unavailable
      end
    end
  end
end

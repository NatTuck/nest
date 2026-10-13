defmodule Nest.TestSupport.OwnerExitProbe do
  @moduledoc """
  TEMPORARY diagnostic. NOT FOR MERGE.

  Captures the `DBConnection` "owner ... exited" / "client ... exited"
  disconnect that `DBConnection.Ownership.Proxy` logs when a test's sandbox
  connection is still held by a client at the moment the test process (the
  owner) goes down, and records which test owned that process.

  The test name comes from `Nest.DataCase.setup_sandbox/2`, which registers
  `{test_pid, {module, describe, test}}` in the `:nest_owner_exit_probe` ETS
  table. The disconnect message names the owner pid, so the lookup is exact.

  Why a logger handler rather than a scan of live processes: the message is
  *un-enriched* (no "Client ... is still using a connection from owner at
  location:" block), and `DBConnection.Ownership.Proxy.pruned_stacktrace/1`
  returns `[]` only when `Process.info(pid, :current_stacktrace)` fails. So the
  client was already dead when the owner's `:DOWN` was handled, and a scan for
  live borrowers would find nothing. The pid we are given is the owner's, and
  the owner's test is what we need.
  """

  @table :nest_owner_exit_probe
  @path "/tmp/owner-exit-probe.log"
  # Only the events we are hunting, so a run's evidence can be read without
  # wading through every other :error the suite deliberately logs.
  @hits "/tmp/owner-exit-hits.log"

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_handler_config(_old, new), do: {:ok, new}
  def filter_config(config), do: config

  def log(%{level: level, msg: msg} = event, _config) do
    text = to_text(msg)

    if level == :error do
      record(text, event)
    end

    :ok
  end

  defp record(text, event) do
    owner = owner_pid(text)

    line = [
      "\n=== owner-exit-probe ",
      inspect(System.system_time(:millisecond)),
      " level=",
      inspect(Map.get(event, :level)),
      " owner=",
      inspect(owner),
      " test=",
      inspect(lookup(owner)),
      " last_started=",
      inspect(last_started()),
      "\nborrowers(still alive, owner in $callers): ",
      inspect(borrowers(owner)),
      "\n",
      text,
      "\n"
    ]

    File.write!(@path, line, [:append])

    if String.contains?(text, "disconnected:") and String.contains?(text, "exited") do
      File.write!(@hits, line, [:append])
    end
  rescue
    _ -> :ok
  end

  # The pid named by "owner #PID<0.123.0> exited". Elixir inspects pids as
  # `#PID<a.b.c>`; `:erlang.list_to_pid/1` wants the Erlang spelling `<a.b.c>`,
  # so the `#` has to go or it raises and the lookup silently degrades.
  defp owner_pid(text) do
    case Regex.run(~r/owner #PID<([0-9]+\.[0-9]+\.[0-9]+)> exited/, text) do
      [_, inner] -> :erlang.list_to_pid(String.to_charlist("<" <> inner <> ">"))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp lookup(nil), do: :no_owner_in_message

  defp lookup(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, test}] -> test
      _ -> :unknown_owner
    end
  rescue
    _ -> :ets_unavailable
  end

  defp last_started do
    case :ets.lookup(@table, :last_started) do
      [{:last_started, test}] -> test
      _ -> :none
    end
  rescue
    _ -> :ets_unavailable
  end

  # Best effort, and expected to be empty when the client is already dead.
  defp borrowers(nil), do: []

  defp borrowers(owner) do
    for pid <- Process.list(),
        info = Process.info(pid, [:dictionary, :current_stacktrace, :initial_call]),
        info != nil,
        callers = Keyword.get(Keyword.get(info, :dictionary, []), :"$callers"),
        is_list(callers),
        owner in callers do
      {pid, Keyword.get(info, :initial_call), Keyword.get(info, :current_stacktrace)}
    end
  rescue
    _ -> []
  end

  # Erlang logger event messages arrive as chardata, a format/args pair, or a
  # zero-arity function (DBConnection logs a function). Never raise: a raising
  # handler would take logging down with it.
  defp to_text(msg) do
    case msg do
      {:string, s} -> IO.iodata_to_binary(s)
      {format, args} when is_list(args) -> IO.iodata_to_binary(:io_lib.format(format, args))
      fun when is_function(fun, 0) -> IO.iodata_to_binary(fun.())
      other -> inspect(other)
    end
  rescue
    _ -> inspect(msg)
  end
end

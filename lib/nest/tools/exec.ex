defmodule Nest.Tools.Exec do
  @moduledoc """
  Lazily starts the `:erlexec` application on first use.

  `:erlexec`'s `exec` gen_server sleeps a hardcoded 350ms in `init/1`
  (`deps/erlexec/src/exec.erl`, the `after 350 ->` clause) to check
  whether its port program died immediately. Starting the app through
  the application controller would pay that 350ms on every boot, so
  outside prod the app is deliberately absent from `nest`'s
  `applications` list (see `mix.exs`) and started here instead, on the
  first shell command. In prod the app is still started by the
  application controller, so `ensure_started/0` is a cheap no-op there.

  Every call site that reaches an `:exec` function backed by the `exec`
  process (`:exec.run/2`, `:exec.send/2`, `:exec.stop/1`,
  `:exec.kill/2`) must call `ensure_started/0` first. (`:exec.status/1`
  is a pure decoder and needs nothing.)
  """

  @doc """
  Ensure the `:erlexec` application is started. Idempotent and cheap once
  the app is running.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    case Application.ensure_all_started(:erlexec) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start :erlexec: #{inspect(reason)}"
    end
  end
end

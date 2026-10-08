defmodule Nest.Agents.Agent.WaitBudget do
  @moduledoc """
  The shared time budget for the blocking sub-agent waits.

  `agents-spawn`/`agents-query` (blocking and async) and `agents-wait` all
  bound themselves by the same default wall-clock timeout and poll on the
  same `receive ... after` slice. Defining both here — instead of once per
  module with a "mirrors the other" comment — keeps them from drifting.

  The values are plain functions, not module attributes, so every call site
  reads the one definition; a remote function cannot be evaluated at compile
  time, and none of these call sites need a compile-time constant.
  """

  @default_wait_ms 300_000
  @wait_slice_ms 250

  @doc "The default wall-clock wait for a sub-agent result, in milliseconds."
  @spec default_wait_ms() :: pos_integer()
  def default_wait_ms, do: @default_wait_ms

  @doc "The `receive ... after` slice used while polling for a wait, in milliseconds."
  @spec wait_slice_ms() :: pos_integer()
  def wait_slice_ms, do: @wait_slice_ms
end

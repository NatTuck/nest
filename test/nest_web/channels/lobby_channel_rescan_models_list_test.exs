defmodule NestWeb.LobbyChannel.RescanModelsListTest do
  @moduledoc """
  Tests for `NestWeb.LobbyChannel.rescan_models_list/2`.

  The function spawns a `Task.async/1` to refresh the model
  catalog with a timeout budget, then `Task.yield`s the result.
  Because Mimic stubs are per-process and the Task runs in its
  own pid, we exercise the closure-shaped `runner` parameter
  directly — `set_mimic_global` is unnecessary.
  """
  # `async: false` because the production default runner touches
  # `Models.refresh/1`, which rewrites the model cache the other
  # concurrent async tests rely on. The custom-runner tests
  # themselves are isolated, but ExUnit serializes the whole
  # module rather than per-test.
  use NestWeb.ChannelCase, async: false

  alias NestWeb.LobbyChannel

  import ExUnit.CaptureLog

  describe "rescan_models_list/2" do
    test "returns the runner's result on the happy path" do
      runner = fn -> [%{"name" => "x", "provider" => "y", "context_limit" => nil}] end

      assert LobbyChannel.rescan_models_list(100, runner) ==
               [%{"name" => "x", "provider" => "y", "context_limit" => nil}]
    end

    test "falls back to safe_models_list/0 when the inner runner raises" do
      # `Task.async/1` is linked to the caller — an unhandled raise
      # in the inner function becomes an EXIT signal that would
      # kill the test before `rescan_models_list/2`'s `rescue` arm
      # runs. Trapping exits keeps the link but converts the signal
      # to a mailbox message.
      Process.flag(:trap_exit, true)

      # The function calls `safe_models_list/0` from the test's
      # pid, where `Models.list/0` succeeds against the running
      # `Nest.Models` GenServer — so the assertion is on "returns
      # a list, doesn't crash". The raise inside the runner makes
      # the supervised Task die; `Task.Supervisor` logs the
      # exception before the rescue arm runs. Capture it and
      # assert it's the expected error path, not noise.
      runner = fn -> raise "models.list timeout" end

      log =
        capture_log(fn ->
          assert is_list(LobbyChannel.rescan_models_list(100, runner))
        end)

      assert log =~ "models.list timeout"
    end

    test "catches a :timeout exit raised inside the task" do
      # `Task.yield/2` re-raises an inner exit as `{:exit, reason}`
      # to the caller, which falls through to `safe_models_list/0`.
      # We trap exits because `Task.async/1` is linked — the EXIT
      # signal would otherwise kill the test before the function's
      # `catch :exit, _ -> safe_models_list()` branch runs.
      Process.flag(:trap_exit, true)

      runner = fn -> exit({:timeout, :boom}) end

      log =
        capture_log(fn ->
          assert is_list(LobbyChannel.rescan_models_list(100, runner))
        end)

      assert log =~ ":timeout, :boom"
    end
  end
end

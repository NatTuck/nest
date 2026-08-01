defmodule NestWeb.LobbyChannel.RescanModelsListTest do
  @moduledoc """
  Tests for `NestWeb.LobbyChannel.rescan_models_list/1`.

  The lobby channel's `rescan_models` push uses a spawned
  process to refresh the model catalog with a timeout
  budget; this file covers the public `rescan_models_list/1`
  helper directly with a stubbed `Models.list/0` — the
  spawned-process approach makes Mimic stubbing impossible at
  the boundary (Mimic stubs are per-process).
  """

  use NestWeb.ChannelCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Models

  setup :set_mimic_global

  describe "rescan_models_list/1" do
    test "returns the live catalog on the happy path" do
      # `rescan_models_list/1` exists as a public helper so we
      # can drive it directly with a stubbed `Models.list/0`
      # — the spawned-process approach used by the lobby
      # channel's `rescan_models` push makes stubbing at the
      # boundary impossible (Mimic stubs are per-process).
      expect(Models, :refresh, fn _opts -> :ok end)

      expect(Models, :list, fn ->
        [%{"name" => "x", "provider" => "y", "context_limit" => nil}]
      end)

      _ = :sys.get_state(Models)

      assert NestWeb.LobbyChannel.rescan_models_list() == [
               %{"name" => "x", "provider" => "y", "context_limit" => nil}
             ]
    end

    test "falls back to safe_models_list/0 when the inner task raises" do
      # The inner `Task.async` re-raises the user's exception
      # as `:exit, reason` to the calling process. The
      # channel's `rescue _ -> safe_models_list()` catches
      # the raised error, and `safe_models_list/0` rescues
      # the raised `Models.list/0` call — so the function
      # ultimately returns `[]`. We drive this through a
      # raised exception in the task (rather than hanging
      # on the budget-elapsed path) to keep the test fast
      # and sleep-free.
      #
      # The intentional raise produces a Task terminating
      # error log — capture and assert it's the expected
      # error path, not noise.
      Process.flag(:trap_exit, true)

      stub(Models, :refresh, fn _opts -> :ok end)

      log =
        capture_log(fn ->
          stub(Models, :list, fn ->
            raise "models.list timeout"
          end)

          assert NestWeb.LobbyChannel.rescan_models_list() == []
        end)

      assert log =~ "models.list timeout"
    end

    test "catches a :timeout exit raised inside the task" do
      # `Task.async` re-raises the inner exception as
      # `:exit, {:timeout, …}` to the calling process when
      # `Task.yield/3` returns the exit reason. Make the
      # inner function exit explicitly so the channel's
      # `catch :exit, _ -> safe_models_list()` branch
      # runs. We need to trap exits in the test process
      # because `Task.async` is linked — the EXIT signal
      # would otherwise kill the test before the `catch`
      # can run.
      #
      # The intentional exit produces a Task terminating
      # error log — capture and assert it's the expected
      # error path, not noise.
      Process.flag(:trap_exit, true)

      expect(Models, :refresh, fn _opts -> :ok end)

      log =
        capture_log(fn ->
          expect(Models, :list, fn ->
            exit({:timeout, :boom})
          end)

          _ = :sys.get_state(Models)

          assert NestWeb.LobbyChannel.rescan_models_list() == []
        end)

      assert log =~ ":boom"
    end
  end
end

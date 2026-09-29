defmodule Nest.ModelsRescanTest do
  @moduledoc """
  Tests for the streaming scan state machine in `Nest.Models`.

  These drive `Nest.Models.handle_info/2` and `handle_cast/2`
  directly with a hand-built state. No timers, no HTTP, no running
  singleton, no provider tasks and no PubSub subscription: the
  contract lives in the state the GenServer transitions through.
  Broadcasts are a thin side effect of the same transitions and are
  covered by `Nest.ModelsTest` (the real `{:models_updated, _}` from a
  scan) and `NestWeb.LobbyChannelRescanModelsTest` (consumption of the
  terminal `{:models_scan_complete, _}`).

    * each provider's answer is merged and the last answer finishes
      the scan;
    * a provider's stale entries are dropped before its new answer is
      merged;
    * a refresh while a live scan is in flight joins it, and a scan
      whose deadline already fired is replaced;
    * a scan with no auto-providers finalizes immediately instead of
      leaving the scan live forever (which makes every later refresh a
      no-op).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.DotConfig.Model
  alias Nest.Models

  defp state(scan) do
    %{
      static_config: %{models: %{}, providers: %{}},
      auto_models: %{},
      context_limits: %{},
      scan: scan,
      last_scan_id: nil
    }
  end

  defp scan(pending, auto_models \\ %{}, context_limits \\ %{}, opts \\ []) do
    %{
      id: Keyword.get(opts, :id, 1),
      pending: MapSet.new(pending),
      auto_models: auto_models,
      context_limits: context_limits,
      timer: Keyword.get(opts, :timer),
      deadline_fired: Keyword.get(opts, :deadline_fired, false)
    }
  end

  defp model(name, provider) do
    %Model{name: name, provider_name: provider, context_limit: nil, multi_modal: nil}
  end

  describe "provider results" do
    test "merges each provider's answer and finishes on the last" do
      state =
        state(scan(["a", "b"]))
        |> handle_result("a", %{"a-model" => model("a-model", "a")}, %{"a" => %{}})

      # First answer ends with provider "b" still pending: scan stays
      # active, accumulator holds what we have.
      assert state.scan.pending == MapSet.new(["b"])
      assert Map.keys(state.scan.auto_models) == ["a-model"]

      state =
        state
        |> handle_result("b", %{"b-model" => model("b-model", "b")}, %{"b" => %{}})

      # Last answer folds the accumulator into the canonical fields
      # and ends the scan.
      assert state.scan == nil
      assert Map.keys(state.auto_models) |> Enum.sort() == ["a-model", "b-model"]
    end

    test "ignores a result from a provider that is not part of the scan" do
      state = state(scan(["a"]))
      unchanged = handle_result(state, "ghost", %{"g" => model("g", "ghost")}, %{})

      assert unchanged.scan.pending == MapSet.new(["a"])
      assert unchanged.scan.auto_models == %{}
    end

    test "ignores a result when no scan is active" do
      idle = state(nil)

      assert {:noreply, ^idle} =
               Models.handle_info(
                 {:models_provider_result, "a", %{"m" => model("m", "a")}, %{}},
                 idle
               )
    end
  end

  describe "provider failures" do
    test "drops the failing provider's stale entries and finishes when it was last" do
      log =
        capture_log(fn ->
          state =
            state(scan(["a"], %{"stale" => model("stale", "a")}, %{"a" => %{"stale" => :x}}))
            |> handle_failure("a", :timeout)

          assert state.scan == nil
          assert state.auto_models == %{}
          assert state.context_limits == %{}
        end)

      # The failure is surfaced, not swallowed silently.
      assert log =~ "provider a failed"
    end
  end

  describe "stale providers" do
    test "an answer replaces the provider's previous entries instead of merging onto them" do
      state =
        state(
          scan(
            ["a"],
            %{"old" => model("old", "a"), "keep" => model("keep", "other")},
            %{"a" => %{"old" => :limit}}
          )
        )
        |> handle_result("a", %{"new" => model("new", "a")}, %{"a" => %{"new" => :limit}})

      assert state.scan == nil
      # "old" (same provider) is gone; "keep" (another provider) survives.
      assert Map.keys(state.auto_models) |> Enum.sort() == ["keep", "new"]
      assert state.context_limits == %{"a" => %{"new" => :limit}}
    end
  end

  describe "scan deadline" do
    test "finalizing a scan cancels its deadline timer" do
      timer = Process.send_after(self(), :deadline_should_be_cancelled, 60_000)
      state = state(scan(["a"], %{}, %{}, timer: timer))

      state =
        handle_result(state, "a", %{"m" => model("m", "a")}, %{"a" => %{}})

      assert state.scan == nil
      assert Process.read_timer(timer) == false
      refute_received :deadline_should_be_cancelled
    end

    test "the deadline marks completion without ending the scan" do
      timer = Process.send_after(self(), :deadline_should_be_cancelled, 60_000)
      state = state(scan(["a"], %{}, %{}, timer: timer))

      assert {:noreply, next} = Models.handle_info(:models_scan_deadline, state)

      # The scan stays alive to accept late provider answers, and is
      # marked so a late finalize won't announce a second completion.
      assert next.scan != nil
      assert next.scan.deadline_fired == true

      # The timer already fired in production; cancel the synthetic
      # one so it can't leak into a later test.
      Process.cancel_timer(timer)
    end

    test "a late provider result after the deadline finalizes the scan" do
      state = state(scan(["a"], %{}, %{}, deadline_fired: true))

      state =
        handle_result(state, "a", %{"m" => model("m", "a")}, %{"a" => %{}})

      assert state.scan == nil
      assert Map.keys(state.auto_models) == ["m"]
    end

    test "a deadline with no active scan is a no-op" do
      idle = state(nil)

      assert {:noreply, ^idle} = Models.handle_info(:models_scan_deadline, idle)
    end
  end

  describe "scan start" do
    test "a refresh while a scan is live joins it instead of starting another" do
      live = state(scan(["a"], %{}, %{}, id: 7))

      assert {:noreply, next} = Models.handle_cast(:refresh, live)
      assert next.scan.id == 7
      assert next.last_scan_id == nil

      # The joined scan still finalizes exactly as normal.
      done = handle_result(next, "a", %{"m" => model("m", "a")}, %{"a" => %{}})
      assert done.scan == nil
      assert Map.keys(done.auto_models) == ["m"]
    end

    test "a refresh after the deadline fired starts a fresh scan" do
      fired = state(scan(["a"], %{}, %{}, id: 7, deadline_fired: true))

      assert {:noreply, next} = Models.handle_cast(:refresh, fired)

      # No auto-providers, so the fresh scan finalizes on the same tick.
      assert next.scan == nil
      assert next.last_scan_id != nil
      assert next.last_scan_id != 7
    end

    test "a scan with no auto-providers completes immediately and later refreshes still run" do
      assert {:noreply, first} = Models.handle_cast(:refresh, state(nil))
      assert first.scan == nil
      assert is_integer(first.last_scan_id)

      assert {:noreply, second} = Models.handle_cast(:refresh, first)
      assert second.scan == nil
      assert second.last_scan_id != first.last_scan_id
    end
  end

  defp handle_result(state, name, models, limits) do
    {:noreply, next} = Models.handle_info({:models_provider_result, name, models, limits}, state)
    next
  end

  defp handle_failure(state, name, reason) do
    {:noreply, next} = Models.handle_info({:models_provider_failed, name, reason}, state)
    next
  end
end

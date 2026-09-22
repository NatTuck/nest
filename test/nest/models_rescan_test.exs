defmodule Nest.ModelsRescanTest do
  @moduledoc """
  Tests for the streaming scan accumulator in `Nest.Models`.

  These drive `Nest.Models.handle_info/2` directly with a
  hand-built state. No timers, no HTTP, no running singleton and no
  global stubs — the deadline/HTTP path is deliberately not
  exercised here because the 5s wall clock can't be observed under
  the suite's 5s cap. What matters is the accumulator contract:
  each provider's answer is merged, the last answer finishes the
  scan, and a provider's stale entries are dropped before its new
  answer is merged.
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
      scan: scan
    }
  end

  defp scan(pending, auto_models \\ %{}, context_limits \\ %{}) do
    %{pending: MapSet.new(pending), auto_models: auto_models, context_limits: context_limits}
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

  defp handle_result(state, name, models, limits) do
    {:noreply, next} = Models.handle_info({:models_provider_result, name, models, limits}, state)
    next
  end

  defp handle_failure(state, name, reason) do
    {:noreply, next} = Models.handle_info({:models_provider_failed, name, reason}, state)
    next
  end
end

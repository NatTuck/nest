defmodule Nest.ModelsRescanCompletionTest do
  @moduledoc """
  Regression tests for the rescan completion contract in `Nest.Models`.

  Intended behavior (do not weaken without an explicit user
  instruction): a scan broadcasts `{:models_updated, _}` for each
  provider as it answers — those are *partials* — and broadcasts
  exactly one terminal `{:models_scan_complete, %{scan_id: id}}`
  only after every provider has answered or the scan's deadline has
  fired. A fast first provider must never look like completion, and a
  scan with no auto-providers must complete immediately instead of
  leaving the scan live forever (which makes every later rescan a
  no-op).
  """
  use ExUnit.Case, async: false

  import Mimic

  alias Nest.DotConfig
  alias Nest.Models

  setup :set_mimic_global

  setup do
    original = :sys.get_state(Models)

    on_exit(fn ->
      :sys.replace_state(Models, fn current ->
        cancel_current_timer(current)
        original
      end)
    end)

    :ok
  end

  describe "scan completion" do
    test "a partial is not completion, and completion fires once after the last provider" do
      put_providers([fast_provider(), slow_provider()])
      stub_gated_models()

      Phoenix.PubSub.subscribe(Nest.PubSub, "models")

      Models.refresh()

      # The fast provider answers while slow is still gated: this is a
      # partial, not completion. The scan is still live (slow pending),
      # so completion cannot have fired.
      assert_receive {:models_updated, partial}, 1_000
      assert Enum.any?(partial, &(&1["name"] == "fast-1"))
      assert %{scan: %{pending: pending}} = :sys.get_state(Models)
      assert MapSet.member?(pending, "slow")
      refute_receive {:models_scan_complete, _}, 0

      release("slow")

      assert_receive {:models_scan_complete, %{scan_id: scan_id, models: models}}, 1_000
      assert is_integer(scan_id)
      assert Enum.any?(models, &(&1["name"] == "fast-1"))
      assert Enum.any?(models, &(&1["name"] == "slow-1"))

      # Exactly one completion: the scan is cleared, and no duplicate
      # was delivered alongside the one we consumed.
      assert :sys.get_state(Models).scan == nil
      refute_receive {:models_scan_complete, _}, 0
    end

    test "a refresh while a scan is in flight joins it instead of starting another" do
      put_providers([fast_provider(), slow_provider()])
      stub_gated_models()

      Phoenix.PubSub.subscribe(Nest.PubSub, "models")

      Models.refresh()
      Models.refresh()

      assert_receive {:models_updated, _partial}, 1_000
      assert %{scan: %{pending: pending}} = :sys.get_state(Models)
      assert MapSet.member?(pending, "slow")
      refute_receive {:models_scan_complete, _}, 0

      release("slow")

      assert_receive {:models_scan_complete, _}, 1_000
      # The coalesced refresh did not start a second scan: the scan is
      # cleared and only the one completion was delivered.
      assert :sys.get_state(Models).scan == nil
      refute_receive {:models_scan_complete, _}, 0
    end

    test "the deadline emits completion once and late answers do not re-complete" do
      put_providers([fast_provider(), slow_provider()])
      stub_gated_models()

      Phoenix.PubSub.subscribe(Nest.PubSub, "models")

      Models.refresh()

      assert_receive {:models_updated, _partial}, 1_000

      # The scan stays alive past the deadline (so late answers still
      # update the catalog), but it must announce completion once now.
      timer = :sys.get_state(Models).scan.timer
      Process.cancel_timer(timer)
      send(Models, :models_scan_deadline)

      # The deadline broadcasts the partial catalog, then the one
      # terminal completion.
      assert_receive {:models_updated, deadline_partial}, 1_000
      assert Enum.any?(deadline_partial, &(&1["name"] == "fast-1"))
      refute Enum.any?(deadline_partial, &(&1["name"] == "slow-1"))

      assert_receive {:models_scan_complete, %{models: models}}, 1_000
      assert Enum.any?(models, &(&1["name"] == "fast-1"))
      refute Enum.any?(models, &(&1["name"] == "slow-1"))

      # The deadline announced completion but left the scan live for
      # late answers.
      assert %{scan: %{deadline_fired: true}} = :sys.get_state(Models)

      release("slow")

      # The late final list still arrives...
      assert_receive {:models_updated, late}, 1_000
      assert Enum.any?(late, &(&1["name"] == "slow-1"))
      # ...and the late answer clears the scan without a second
      # completion.
      assert :sys.get_state(Models).scan == nil
      refute_receive {:models_scan_complete, _}, 0
    end

    test "a scan with no auto-providers completes immediately and later rescans still run" do
      put_providers([])

      Phoenix.PubSub.subscribe(Nest.PubSub, "models")

      Models.refresh()

      assert_receive {:models_scan_complete, %{scan_id: scan_id}}, 1_000
      assert is_integer(scan_id)
      assert :sys.get_state(Models).scan == nil

      # A later rescan must start a fresh scan, not no-op on a live one.
      Models.refresh()

      assert_receive {:models_scan_complete, %{scan_id: next_id}}, 1_000
      assert next_id != scan_id
    end
  end

  # -- helpers ------------------------------------------------------

  defp put_providers(providers) do
    map = Map.new(providers, &{&1.name, &1})

    :sys.replace_state(Models, fn state ->
      %{state | static_config: %{models: %{}, providers: map}, scan: nil}
    end)
  end

  defp fast_provider do
    %DotConfig.Provider{name: "fast", base_url: "http://fast.test", auto_models: true}
  end

  defp slow_provider do
    %DotConfig.Provider{name: "slow", base_url: "http://slow.test", auto_models: true}
  end

  defp stub_gated_models do
    stub(Req, :get, fn url, _opts ->
      cond do
        String.contains?(url, "slow.test") ->
          gate("slow")
          ok_models(["slow-1"])

        String.contains?(url, "fast.test") ->
          ok_models(["fast-1"])

        true ->
          {:error, :nxdomain}
      end
    end)
  end

  defp ok_models(names) do
    {:ok, %{status: 200, body: %{"data" => Enum.map(names, &%{"id" => &1})}}}
  end

  # Block the first `/models` request for a provider until the test
  # releases it. The flag lives in the scan task's process dictionary,
  # so that provider's second request (limits) doesn't gate again.
  defp gate(name) do
    key = {:gated, name}

    unless Process.get(key) do
      Process.put(key, true)
      Phoenix.PubSub.subscribe(Nest.PubSub, gate_topic(name))

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  defp release(name) do
    Phoenix.PubSub.broadcast(Nest.PubSub, gate_topic(name), :release)
  end

  defp gate_topic(name), do: "test:models_release:#{name}"

  defp cancel_current_timer(state) do
    case state.scan do
      %{timer: timer} when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end
  end
end

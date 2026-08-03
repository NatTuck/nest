defmodule Nest.Agents.Agent.Broadcasts.ModelMissingTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Broadcasts.ModelMissing` —
  the helper that emits a `chat:status` push for an agent
  whose persisted `model` couldn't be resolved at startup.

  The `broadcast/3` function is a thin Phoenix.PubSub
  wrapper; the test pins its wire shape and exercises the
  `model_label/1` private fallback branches
  (`model_label(nil)`, `model_label(other)`).
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Broadcasts.ModelMissing

  describe "broadcast/3 wire shape" do
    test "status: model_missing, model: {name, provider}, reason: inspected" do
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:test-missing")

      ModelMissing.broadcast(
        "test-missing",
        %{name: "ghost-model", provider: "qwen"},
        :not_found
      )

      assert_receive {:chat_status, payload}, 500
      assert payload.status == "model_missing"
      assert payload.model == %{"name" => "ghost-model", "provider" => "qwen"}
      # Reason comes through `inspect/1` so any term serialises.
      assert payload.reason =~ "not_found"
    end

    test "tolerates a nil model map (transition safety net)" do
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:nil-model")

      ModelMissing.broadcast("nil-model", nil, :no_model)

      assert_receive {:chat_status, payload}, 500
      assert payload.status == "model_missing"
      assert payload.model == nil
      assert payload.reason =~ "no_model"
    end

    test "tolerates non-map models (defensive fallback)" do
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:weird-model")

      ModelMissing.broadcast("weird-model", :just_an_atom, :unknown)

      assert_receive {:chat_status, payload}, 500
      assert payload.model == %{"name" => "just_an_atom"}
    end
  end
end

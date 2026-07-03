defmodule Nest.ModelsTest do
  @moduledoc """
  Tests for the merged model list and per-provider context-limit
  cache managed by `Nest.Models`.

  Regression coverage for the auto-discovery bug where
  `[providers.minimax]` (whose `/v1/models` returns pure OpenAI-shape
  entries with no recognized limit field) was rendered as having
  zero models in `Models.list/0`, because `query_provider/1` derived
  the merged-map names from `list_models_with_limits/1`'s filtered
  output instead of calling `list_models/1` independently.

  ## Synchronization model

  `Nest.Models` is a singleton GenServer shared across tests in the
  whole `mix test` run, so this module is `async: false`. Each test
  stubs `Req.get` (Mimic), casts `Models.refresh/0`, then synchronizes
  by calling `:sys.get_state(Nest.Models)` — which forces the GenServer
  to drain its mailbox, guaranteeing `:refresh` → `:query_auto_providers`
  has completed before assertions run.
  """
  use ExUnit.Case, async: false

  import Mimic

  alias Nest.Models

  setup :set_mimic_global

  setup do
    # Stub the only auto-models provider in test/data/config.toml
    # (`pegasus`) to return a mix of:
    #   * 3 OpenAI-shape entries with only `id` (no limit field) — the
    #     MiniMax regression: names must appear in `Models.list/0`
    #     even though `extract_limit_from_model/1` returns nil for all.
    #   * 1 vLLM-shape entry with `max_model_len` — limits must still
    #     get cached for providers that include recognized fields.
    stub(Req, :get, fn url, _opts ->
      if String.contains?(url, "pegasus") do
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => [
               %{
                 "id" => "MiniMax-M3",
                 "object" => "model",
                 "owned_by" => "minimax",
                 "created" => 1_780_272_000
               },
               %{
                 "id" => "MiniMax-M2.7",
                 "object" => "model",
                 "owned_by" => "minimax",
                 "created" => 1_780_272_000
               },
               %{
                 "id" => "MiniMax-M2.5",
                 "object" => "model",
                 "owned_by" => "minimax",
                 "created" => 1_780_272_000
               },
               %{
                 "id" => "vllm-shape-model",
                 "object" => "model",
                 "max_model_len" => 16_384
               }
             ]
           }
         }}
      else
        {:error, :nxdomain}
      end
    end)

    Models.refresh()
    # Force the GenServer to drain `refresh` → `:query_auto_providers`
    # before the test body runs.
    _ = :sys.get_state(Models)

    # Mimic's `:DOWN` handler clears the stub map for the test pid
    # once it exits *unless* `verify_on_exit!` is set — which we
    # deliberately do NOT register here, because we use `stub` only
    # (no `expect` to verify). That cleanup is what prevents the
    # global stub from leaking into subsequent tests that share the
    # `Nest.Models` singleton GenServer.

    :ok
  end

  describe "merged model list (regression for [providers.minimax])" do
    test "registers names whose entries have no recognized limit field" do
      # Names returned via auto-discovery only (not in static config)
      # show up under the auto-models provider.
      models = Models.list()
      names = models |> Enum.filter(&(&1["provider"] == "pegasus")) |> Enum.map(& &1["name"])

      assert "MiniMax-M3" in names
      assert "MiniMax-M2.7" in names
      # `MiniMax-M2.5` is also defined statically under `model-studio`
      # in `test/data/config.toml`; static config wins the merge, so
      # the merged-map entry for that name resolves to model-studio,
      # not pegasus. Don't assert provider here for it — see the
      # static-config-wins test below.
      assert "vllm-shape-model" in names
    end

    test "static config wins over auto-discovery when a name appears in both" do
      # `MiniMax-M2.5` is statically defined under `model-studio`
      # AND returned by the auto-discovery stub for `pegasus`.
      # Static config has authoritative `provider_name` / context_limit.
      mini = Enum.find(Models.list(), fn m -> m["name"] == "MiniMax-M2.5" end)
      assert mini != nil
      assert mini["provider"] == "model-studio"
      assert mini["context_limit"] == nil
    end

    test "Models.context_limit/2 returns nil for entries with no recognized limit field" do
      assert Models.context_limit("pegasus", "MiniMax-M3") == nil
      assert Models.context_limit("pegasus", "MiniMax-M2.7") == nil
    end

    test "Models.context_limit/2 caches the vLLM-extracted limit when a recognized field is present" do
      assert Models.context_limit("pegasus", "vllm-shape-model") == {:vllm, 16_384}
    end

    test "Models.list/0 surfaces the provider-level default for entries with no per-model limit and no cache hit" do
      # `pegasus` in `test/data/config.toml` has
      # `default-context-limit = 512000` (and the per-model entries
      # `pegasus-per-model-test` and `pegasus-default-only` are also
      # defined). For an auto-discovered entry with no recognized
      # limit field, the effective `context_limit` in `Models.list/0`
      # is the provider default.
      mm3 = Enum.find(Models.list(), fn m -> m["name"] == "MiniMax-M3" end)
      assert mm3 != nil
      assert mm3["provider"] == "pegasus"
      assert mm3["context_limit"] == 512_000
    end

    test "Models.list/0 surfaces the per-model `context-limit` for static-config entries" do
      # `pegasus-per-model-test` is a static-config entry with
      # `context-limit = 32000`. The same provider has a default
      # of 512000, but the per-model value wins.
      per_model = Enum.find(Models.list(), fn m -> m["name"] == "pegasus-per-model-test" end)
      assert per_model != nil
      assert per_model["provider"] == "pegasus"
      assert per_model["context_limit"] == 32_000
    end
  end
end

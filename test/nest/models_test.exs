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
  stubs `Req.get` (Mimic), triggers `Models.refresh/0`, then waits
  for the next `{:models_updated, _}` PubSub broadcast via
  `ModelsTestHelpers.await_models_refresh/0` — which guarantees the
  background scan Task has completed before assertions run.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Models
  alias Nest.Test.ModelsTestHelpers

  # `:sys.replace_state/3` with an explicit timeout: OTP's default is 5000 ms,
  # which is ExUnit's own per-test ceiling, so a wedged server would surface as
  # a test timeout rather than as the stuck call it is (#21).
  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 500)

  setup :set_mimic_global

  setup do
    test_pid = self()

    # Stub the only auto-models provider in test/data/config.toml
    # (`pegasus`) to return a mix of:
    #   * 3 OpenAI-shape entries with only `id` (no limit field) — the
    #     MiniMax regression: names must appear in `Models.list/0`
    #     even though `extract_limit_from_model/1` returns nil for all.
    #   * 1 vLLM-shape entry with `max_model_len` — limits must still
    #     get cached for providers that include recognized fields.
    #   * 1 image-capable entry with NO limit field — the multi-modal
    #     regression: an image-capable model that reports no context
    #     limit must survive the scan with its capability intact.
    #   * `pegasus-per-model-test` (static, `multi-modal` unset) and
    #     `pegasus-static-audio` (static `multi-modal` set by one test
    #     via `:sys.replace_state`) — the static-vs-detected fixtures.
    #   * `MiniMax-M2.5` is image-capable here while its static twin under
    #     `model-studio` sets nothing — the cross-provider fill-in guard.
    #
    # A second auto provider (`other-auto`, injected by the one-request
    # test) is answered too, so a scan with two providers can be counted.
    # Every request is also reported to the test process so a test can
    # assert how many `/models` requests a provider scan costs.
    stub(Req, :get, fn url, _opts ->
      send(test_pid, {:models_req_get, url})

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
                 "created" => 1_780_272_000,
                 # Image-capable on purpose: `MiniMax-M2.5` is also a static
                 # entry under the unscanned `model-studio`, so this is the
                 # same-name/different-provider pair the fill-in must NOT cross.
                 "input_modalities" => ["text", "image"]
               },
               %{
                 "id" => "vllm-shape-model",
                 "object" => "model",
                 "max_model_len" => 16_384
               },
               %{
                 "id" => "MiniMax-VL",
                 "object" => "model",
                 "owned_by" => "minimax",
                 "input_modalities" => ["text", "image"]
               },
               %{
                 "id" => "pegasus-per-model-test",
                 "object" => "model",
                 "architecture" => %{"input_modalities" => ["text", "image", "file"]}
               },
               %{
                 "id" => "pegasus-static-audio",
                 "object" => "model",
                 "input_modalities" => ["text", "image"]
               }
             ]
           }
         }}
      else
        if String.contains?(url, "other-auto") do
          {:ok, %{status: 200, body: %{"data" => [%{"id" => "other-auto-model"}]}}}
        else
          {:error, :nxdomain}
        end
      end
    end)

    # Kick a scan and wait for the broadcast so the cache is
    # populated before the test body runs.
    ModelsTestHelpers.await_models_refresh()

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

  describe "multi_modal discovery" do
    test "emits a detected multi_modal for an auto-discovered model with no context limit" do
      # `MiniMax-VL` reports image input and no context limit. The
      # capability must survive the scan — the limits pass keeps one
      # entry per model — and its limit still resolves through the
      # provider default.
      vl = Enum.find(Models.list(), fn m -> m["name"] == "MiniMax-VL" end)

      assert vl != nil
      assert vl["provider"] == "pegasus"
      assert vl["multi_modal"] == %{"input" => ["image"]}
      assert vl["context_limit"] == 512_000
    end

    test "emits a static multi_modal verbatim, including for a model no scan covers" do
      # `model-studio` is not an auto-models provider, so `qwen3.5-plus`
      # appears in no scan at all: its static `multi-modal` is the only
      # source and is emitted verbatim.
      qwen = Enum.find(Models.list(), fn m -> m["name"] == "qwen3.5-plus" end)

      assert qwen != nil
      assert qwen["provider"] == "model-studio"
      assert qwen["multi_modal"] == %{"input" => ["image"]}
    end

    test "fills in a static nil multi_modal from the same provider's scan" do
      # `pegasus-per-model-test` is a static entry under the scanned
      # `pegasus` provider with no `multi-modal`; the provider reports
      # image input for it. The static context limit is untouched.
      model = Enum.find(Models.list(), fn m -> m["name"] == "pegasus-per-model-test" end)

      assert model != nil
      assert model["provider"] == "pegasus"
      assert model["multi_modal"] == %{"input" => ["image"]}
      assert model["context_limit"] == 32_000
    end

    test "does not fill in from a same-named model found under another provider" do
      # `MiniMax-M2.5` is a static entry under the unscanned `model-studio`
      # with no `multi-modal`, while the `pegasus` scan reports an
      # image-capable model of the same name. The fill-in is keyed on the
      # {provider, name} pair — as the context-limit cache is — so another
      # provider's capability must not land on this entry.
      model = Enum.find(Models.list(), fn m -> m["name"] == "MiniMax-M2.5" end)

      assert model != nil
      assert model["provider"] == "model-studio"
      assert model["multi_modal"] == nil
    end

    test "a static multi_modal is never overwritten by a differing discovery answer" do
      # Inject a static `pegasus-static-audio` whose `multi-modal` uses
      # a vocabulary the provider's answer ("image") does not match.
      # The setup's scan has already cached that provider's answer for
      # this name; the static value must be emitted verbatim rather
      # than replaced by the detected one.
      previous = :sys.get_state(Models, 500).static_config

      static_model = %Nest.DotConfig.Model{
        name: "pegasus-static-audio",
        provider_name: "pegasus",
        multi_modal: %{"input" => ["audio"]}
      }

      replace_state(Models, fn state ->
        static_config = %{
          previous
          | models: Map.put(previous.models, "pegasus-static-audio", static_model)
        }

        %{state | static_config: static_config}
      end)

      on_exit(fn ->
        replace_state(Models, fn state -> %{state | static_config: previous} end)
      end)

      model = Enum.find(Models.list(), fn m -> m["name"] == "pegasus-static-audio" end)

      assert model != nil
      assert model["provider"] == "pegasus"
      # The provider answered `["text", "image"]`; static config said
      # `audio`, and static config wins.
      assert model["multi_modal"] == %{"input" => ["audio"]}
    end
  end

  describe "single /models request per provider (regression: duplicate GET)" do
    test "a scan costs one request per provider, not one per scan" do
      # The setup's scan covered `pegasus`, the config's only auto-models
      # provider; consume that request so what is left is this test's own.
      assert_received {:models_req_get, setup_url}
      assert String.contains?(setup_url, "pegasus")
      assert String.ends_with?(setup_url, "/models")

      # A second auto-models provider, so "one request per provider" is
      # distinguishable from "one request per scan". It is injected here
      # rather than added to `test/data/config.toml` so that no other test
      # file's scan grows a provider whose `/models` URL it does not stub.
      inject_second_provider()
      ModelsTestHelpers.await_models_refresh()

      assert_receive {:models_req_get, first}, 1_000
      assert_receive {:models_req_get, second}, 1_000
      refute_received {:models_req_get, _}

      # One request each, and only one: pre-fix `query_provider/1` called
      # `ChatModel.list_models/1` *and* `list_models_with_limits/1`, each
      # fetching the same `/models` URL, so this scan would have left four.
      assert Enum.sort([first, second]) == [
               "http://other-auto.local/v1/models",
               "http://pegasus-probe.local/olla/models"
             ]
    end
  end

  # Add an auto-models provider to the running singleton's static config,
  # restoring the previous snapshot afterwards. The stub answers its URL.
  defp inject_second_provider do
    previous = :sys.get_state(Models, 500).static_config

    provider = %Nest.DotConfig.Provider{
      name: "other-auto",
      base_url: "http://other-auto.local/v1",
      api_key: "test",
      protocol: "openai",
      auto_models: true,
      tags: [],
      models: []
    }

    replace_state(Models, fn state ->
      static_config = %{
        previous
        | providers: Map.put(previous.providers, "other-auto", provider)
      }

      %{state | static_config: static_config}
    end)

    on_exit(fn ->
      replace_state(Models, fn state -> %{state | static_config: previous} end)
    end)
  end

  describe "scan completion broadcast" do
    test "a scan emits its terminal {:models_scan_complete, _} exactly once after models_updated" do
      Phoenix.PubSub.subscribe(Nest.PubSub, "models")

      # `rescan/0` returns the id of the scan that covers this request,
      # so the terminal event can be matched to *this* scan even if the
      # setup's own completion is still sitting in the mailbox.
      scan_id = Models.rescan()

      assert_receive {:models_updated, _payload}, 1_000

      assert_receive {:models_scan_complete, %{scan_id: ^scan_id, models: models}}, 1_000
      assert is_integer(scan_id)
      assert Enum.any?(models, &(&1["name"] == "MiniMax-M3"))

      # Exactly one terminal event per scan.
      refute_receive {:models_scan_complete, %{scan_id: ^scan_id}}, 0

      Phoenix.PubSub.unsubscribe(Nest.PubSub, "models")
    end
  end

  describe "reload_static/0" do
    test "re-reads ~/.config/nest/config.toml" do
      # The default `Models.refresh/0` keeps the static config
      # captured at `init/1`. The new `Models.reload_static/0`
      # re-reads from disk — so a user adding a new
      # `[providers.<n>]` entry to `config.toml` sees it in
      # `Models.list/0` without restarting the app.
      #
      # The setup above already populated `state.static_config`
      # with the real `test/data/config.toml` (via init +
      # `Models.refresh/0`). We stub `DotConfig.load/0` here so
      # a synthetic model appears only after a reload — the
      # pre-reload `Models.list/0` should NOT have it.

      # Snapshot the current static config (loaded from the
      # real `test/data/config.toml` by `init/1` + the
      # setup's `Models.refresh/0`). We use this after the
      # test to restore the canonical state for any
      # subsequent tests in the file.
      pre_reload_static =
        :sys.get_state(Models, 500)
        |> Map.fetch!(:static_config)

      # Stub `DotConfig.load/0` for this test only. The call
      # returns a config with the canonical test `pegasus`
      # provider (so auto-discovery continues to produce the
      # regression-test names) plus one extra static model
      # entry that proves the reload actually re-read the
      # file.
      Nest.DotConfig
      |> stub(:load, fn ->
        pegasus = %Nest.DotConfig.Provider{
          name: "pegasus",
          auto_models: true,
          base_url: "http://pegasus.local",
          api_key: "test",
          default_context_limit: 512_000
        }

        reload_model = %Nest.DotConfig.Model{
          name: "reload-only-model",
          provider_name: "synthetic",
          context_limit: 8000
        }

        pegasus_model = %Nest.DotConfig.Model{
          name: "pegasus-static",
          provider_name: "pegasus",
          context_limit: 8000
        }

        {:ok,
         %{
           providers: %{"pegasus" => pegasus},
           models: %{
             "reload-only-model" => reload_model,
             "pegasus-static" => pegasus_model
           }
         }}
      end)

      Models.reload_static()

      names = Models.list() |> Enum.map(& &1["name"])
      # Reloaded static-only entry:
      assert "reload-only-model" in names
      # Static entry alongside auto-discovery:
      assert "pegasus-static" in names
      # Auto-discovered entry from pegasus (the `Req.get`
      # stub from setup supplies these names):
      assert "MiniMax-M3" in names

      # Restore the snapshot taken before this test so the
      # next test sees the canonical catalog (the reload
      # stub above wiped the real `static_config`).
      replace_state(Models, fn state ->
        %{state | static_config: pre_reload_static}
      end)
    end

    test "plain refresh/0 keeps the previously-captured static_config snapshot" do
      # `Models.refresh/0` (no opts) does not reload static config.
      # If a user adds a new `[providers.<n>]` block to
      # `config.toml` and calls `Models.refresh()` without opts,
      # the new provider stays invisible until app restart (or
      # until they call `reload_static/0` explicitly).

      # Stub `DotConfig.load/0` to return a synthetic config.
      # Even though our stub fires, the refresh-without-reload
      # path must NOT call it (it doesn't reload from disk).
      Nest.DotConfig
      |> stub(:load, fn ->
        {:ok,
         %{
           providers: %{},
           models: %{
             "should-not-appear" => %Nest.DotConfig.Model{
               name: "should-not-appear",
               provider_name: "never",
               context_limit: 1
             }
           }
         }}
      end)

      Models.refresh()
      ModelsTestHelpers.await_models_refresh()

      names = Models.list() |> Enum.map(& &1["name"])
      refute "should-not-appear" in names
    end

    test "keeps the previous static_config snapshot when DotConfig.load/0 returns an error" do
      # Malformed TOML should not wipe the model catalog. The
      # GenServer logs and discards the error; the prior
      # `state.static_config` survives.
      #
      # The reload error fires a `Logger.error` from
      # `Models.handle_call(:reload_static, ...)` — capture
      # it and assert it's the expected error path, not noise.
      current = Models.list()
      current_names = Enum.map(current, & &1["name"])

      Nest.DotConfig
      |> stub(:load, fn -> {:error, :parse_failed} end)

      log =
        capture_log(fn ->
          Models.reload_static()

          assert Enum.map(Models.list(), & &1["name"]) == current_names
        end)

      assert log =~ "Failed to reload static config"
    end
  end
end

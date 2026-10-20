defmodule Nest.ChatModel.ListModelsTest do
  @moduledoc """
  Response-shape coverage for `Nest.ChatModel.list_models/1` and
  `Nest.ChatModel.list_models_with_limits/1`, focused on the cases
  where the response body comes from an OpenAI-compatible provider
  that does not follow one of the recognized
  `extract_limit_from_model/1` shapes (vLLM / OpenRouter / llama.cpp).

  ## Regression: [providers.minimax] auto-discovery

  `api.minimax.io/v1/models` returns pure OpenAI-shape entries with
  only `created` / `id` / `object` / `owned_by` fields. Pre-fix:
  - `list_models_with_limits/1` returned `[]` for such bodies
    (correct), but
  - `Nest.Models.query_provider/1` (private) derived the merged
    model list from that filtered result, so the entire provider's
    models disappeared from `Models.list/0` even though the network
    call succeeded.

  Post-fix: `list_models/1` surfaces names independently of
  `list_models_with_limits/1`, so OpenAI-shape entries with no
  recognized limit field still appear in `Models.list/0` with
  `context_limit: nil` (truthful cache miss).

  ## Shape symmetry

  `extract_all_models/1` previously recognized `id` in OpenAI-shape
  bodies and `name` in Ollama-shape bodies, asymmetrically with
  `Discover.model_id/1` which handles either field in either shape.
  The fix unifies both paths through `Discover.model_id/1`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.ChatModel
  alias Nest.DotConfig

  setup :verify_on_exit!

  describe "list_models/1 response-shape coverage" do
    test "list_models/1 reads the `name` field in OpenAI-shape bodies" do
      provider = %DotConfig.Provider{
        name: "weird-openai-shape",
        base_url: "http://api.test/v1",
        api_key: "k",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => [
               %{"id" => "from-id"},
               %{"name" => "from-name"},
               %{"id" => "with-limit", "max_model_len" => 4096}
             ]
           }
         }}
      end)

      names = ChatModel.list_models(provider)
      assert "from-name" in names
      assert length(names) == 3
    end

    test "list_models_with_limits/1 returns [] when no recognized limit field is present" do
      provider = %DotConfig.Provider{
        name: "no-limit-shape",
        base_url: "http://api.test/v1",
        api_key: "k",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{"data" => [%{"id" => "model-a"}, %{"id" => "model-b"}]}
         }}
      end)

      assert ChatModel.list_models_with_limits(provider) == []
    end

    test "list_models_with_limits/1 returns entries with recognized limits alongside unmatched ones" do
      # Mixed body: some entries have a vLLM-style `max_model_len`,
      # others don't. The ones without are dropped (silently, per
      # the `with` clause in `list_models_with_limits_from_body/1`);
      # the ones with are returned. Confirms the cache side stays
      # filtered even though the merged-map side is not (see
      # `Nest.ModelsTest`).
      provider = %DotConfig.Provider{
        name: "mixed-shape",
        base_url: "http://api.test/v1",
        api_key: "k",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      body = %{
        "data" => [
          %{"id" => "no-limit"},
          %{"id" => "with-limit", "max_model_len" => 4096}
        ]
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert [%{name: "with-limit", source: :vllm, limit: 4096}] =
               ChatModel.list_models_with_limits(provider)
    end
  end

  describe "list_models_with_metadata/1" do
    test "returns one entry per model with source, limit and multi_modal independently nullable" do
      provider = %DotConfig.Provider{
        name: "metadata-shape",
        base_url: "http://api.test/v1",
        api_key: "k",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      body = %{
        "data" => [
          %{"id" => "text-only-no-limit"},
          %{"id" => "with-limit", "max_model_len" => 4096},
          %{"id" => "declared-text-only", "input_modalities" => ["text"]},
          %{"id" => "image-no-limit", "input_modalities" => ["text", "image"]},
          %{"id" => "image-and-limit", "max_model_len" => 8192, "input_modalities" => ["image"]}
        ]
      }

      stub(Req, :get, fn _url, _opts -> {:ok, %{status: 200, body: body}} end)

      assert [
               %{name: "text-only-no-limit", source: nil, limit: nil, multi_modal: nil},
               %{name: "with-limit", source: :vllm, limit: 4096, multi_modal: nil},
               %{
                 name: "declared-text-only",
                 source: nil,
                 limit: nil,
                 multi_modal: %{"input" => []}
               },
               %{
                 name: "image-no-limit",
                 source: nil,
                 limit: nil,
                 multi_modal: %{"input" => ["image"]}
               },
               %{
                 name: "image-and-limit",
                 source: :vllm,
                 limit: 8192,
                 multi_modal: %{"input" => ["image"]}
               }
             ] = ChatModel.list_models_with_metadata(provider)
    end

    test "drops entries with no usable id, and returns [] when the fetch fails" do
      provider = %DotConfig.Provider{
        name: "no-id-shape",
        base_url: "http://api.test/v1",
        api_key: "k",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      body = %{
        "data" => [
          %{"max_model_len" => 4096},
          %{"name" => "named-only", "input_modalities" => ["image"]},
          "not-a-model"
        ]
      }

      stub(Req, :get, fn _url, _opts -> {:ok, %{status: 200, body: body}} end)

      assert [
               %{
                 name: "named-only",
                 source: nil,
                 limit: nil,
                 multi_modal: %{"input" => ["image"]}
               }
             ] = ChatModel.list_models_with_metadata(provider)

      stub(Req, :get, fn _url, _opts -> {:error, :econnrefused} end)

      # A failed fetch is a logged, empty result rather than an error
      # tuple: discovery is best-effort. Capture the line so it does
      # not escape into the test log.
      log =
        capture_log(fn ->
          assert ChatModel.list_models_with_metadata(provider) == []
        end)

      assert log =~ "Failed to list models from no-id-shape"
    end
  end

  describe "probe-base-url routing" do
    test "list_models/1 hits probe-base-url when set, NOT base-url" do
      # The provider's chat URL is /v1; the discovery URL is a
      # divergent /olla path. Listing should use the discovery URL
      # because that's where the Olla-shaped metadata lives.
      provider = %DotConfig.Provider{
        name: "typhon",
        base_url: "http://chat.example.com/v1",
        probe_base_url: "http://probe.example.com/olla",
        api_key: "k",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      test_pid = self()

      stub(Req, :get, fn url, _opts ->
        send(test_pid, {:probe_url, url})
        {:ok, %{status: 200, body: %{"data" => [%{"id" => "m1"}]}}}
      end)

      names = ChatModel.list_models(provider)
      assert names == ["m1"]
      assert_received {:probe_url, "http://probe.example.com/olla/models"}
    end
  end
end

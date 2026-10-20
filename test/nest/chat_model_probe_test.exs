defmodule Nest.ChatModelProbeTest do
  @moduledoc """
  Integration tests for the endpoint-probe wiring in `Nest.ChatModel`:
  `build_client_config/2` falling back to the provider config when
  nothing is cached, and the discovery path re-probing on a `404`.

  `probe_and_cache/1` runs the probe in the caller process, so the
  `Req` stubs apply via plain private-mode Mimic and this module can be
  `async: true`. Each test uses a distinct base URL so the shared
  `Nest.EndpointCache` ETS never collides across concurrent tests.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.EndpointCache

  setup :verify_on_exit!

  defp provider(opts) do
    %DotConfig.Provider{
      name: Keyword.get(opts, :name, "probe-wire-test"),
      base_url: Keyword.get(opts, :base_url, "http://api.test.com"),
      api_key: "k",
      protocol: "openai",
      auto_models: true,
      auto_probe: Keyword.get(opts, :auto_probe, true),
      tags: [],
      models: []
    }
  end

  test "build_client_config/2 falls back to the provider config when nothing is cached" do
    p = provider(name: "uncached-openai", base_url: "http://nocache.test")

    assert {:ok, config} = ChatModel.build_client_config(p, "m")
    assert config.client == Nest.LLM.OpenAIClient
    assert config.base_url == "http://nocache.test"
  end

  describe "discovery re-probe on a 404" do
    test "invalidates and discovers the real /models path" do
      base = "http://probe404.test.com"
      p = provider(name: "probe404", base_url: base)

      # naive /models -> 404; /v1/models -> 200 (found by the probe)
      Mimic.stub(Req, :get, fn url, _opts ->
        cond do
          url == base <> "/v1/models" ->
            {:ok, %{status: 200, body: %{"data" => [%{"id" => "m1"}]}}}

          url == base <> "/models" ->
            {:ok, %{status: 404}}

          true ->
            {:ok, %{status: 404}}
        end
      end)

      # chat probe: base 404s, /v1 succeeds
      Mimic.stub(Req, :post, fn url, _opts ->
        if url == base <> "/v1/chat/completions" do
          {:ok, %{status: 200}}
        else
          {:ok, %{status: 404}}
        end
      end)

      # Only the re-probe can produce this list: the naive `/models` URL
      # 404s and `/v1/models` is the only route this stub answers with a
      # body, so the result pins the discovered discovery path too.
      assert ChatModel.list_models(p) == ["m1"]

      EndpointCache.invalidate(p)
    end

    test "does not re-probe when auto_probe is false" do
      base = "http://noprobe.test.com"
      p = provider(name: "noprobe", base_url: base, auto_probe: false)

      Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 404}} end)
      Mimic.reject(Req, :post, 2)

      assert capture_log(fn -> assert ChatModel.list_models(p) == [] end) =~
               "Provider returned status 404 when listing models from noprobe"
    end
  end
end

defmodule Nest.LLM.Discover.ProbeBaseUrlTest do
  @moduledoc """
  Routing tests for `ClientConfig.probe_base_url` in
  `Nest.LLM.Discover.context_limit/1`.

  When a provider configures a separate URL for model discovery
  (e.g. an Olla-listing endpoint at one path, an OpenAI-compatible
  `/v1/chat/completions` at another), `Discover` must route the
  `/models` fetch through `probe_base_url` and leave `base_url`
  for chat. When `probe_base_url` is `nil` (the common case),
  discovery falls back to `base_url`. When both are `nil`, the
  call short-circuits to the 128k default.

  Companion to `Nest.LLM.DiscoverTest` — split off so the
  parent test file stays under the credo 500-line cap.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover

  setup :verify_on_exit!

  @default_limit 128_000

  defp build_config(opts \\ []) do
    %ClientConfig{
      client: Nest.LLM.OpenAIClient,
      base_url: Keyword.get(opts, :base_url, "http://localhost:8080/v1"),
      api_key: Keyword.get(opts, :api_key, "test-key"),
      model: Keyword.get(opts, :model, "test-model"),
      receive_timeout: 5000
    }
  end

  test "uses probe_base_url for the discovery request when set" do
    test_pid = self()

    Mimic.expect(Req, :get, fn url, _opts ->
      send(test_pid, {:discover_url, url})

      {:ok, %{status: 200, body: %{"data" => [%{"id" => "test-model", "max_model_len" => 4096}]}}}
    end)

    config = %{
      build_config(base_url: "http://chat.example.com/v1")
      | probe_base_url: "http://probe.example.com/olla"
    }

    assert Discover.context_limit(config) == {:vllm, 4096}
    assert_received {:discover_url, "http://probe.example.com/olla/models"}
  end

  test "falls back to base_url when probe_base_url is nil" do
    test_pid = self()

    Mimic.expect(Req, :get, fn url, _opts ->
      send(test_pid, {:discover_url, url})
      {:ok, %{status: 200, body: %{"data" => []}}}
    end)

    Discover.context_limit(build_config(base_url: "http://chat.example.com/v1"))
    assert_received {:discover_url, "http://chat.example.com/v1/models"}
  end

  test "falls through to default when both base_url and probe_base_url are nil" do
    config = %{build_config() | base_url: nil, probe_base_url: nil}
    assert Discover.context_limit(config) == {:default, @default_limit}
  end
end

defmodule Nest.LLM.Discover.ProbeBaseUrlTest do
  @moduledoc """
  Routing test for `ClientConfig.probe_base_url` in
  `Nest.LLM.Discover.context_limit/1`.

  When a provider configures a separate URL for model discovery
  (e.g. an Olla-listing endpoint at one path, an OpenAI-compatible
  `/v1/chat/completions` at another), `Discover` must route the
  `/models` fetch through `probe_base_url` and leave `base_url`
  for chat. The fallbacks — `probe_base_url` unset, and both URLs
  unset — are covered by `Nest.LLM.DiscoverTest`.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover

  setup :verify_on_exit!

  test "uses probe_base_url for the discovery request when set" do
    test_pid = self()

    Mimic.expect(Req, :get, fn url, _opts ->
      send(test_pid, {:discover_url, url})

      {:ok, %{status: 200, body: %{"data" => [%{"id" => "test-model", "max_model_len" => 4096}]}}}
    end)

    config = %ClientConfig{
      client: Nest.LLM.OpenAIClient,
      base_url: "http://chat.example.com/v1",
      probe_base_url: "http://probe.example.com/olla",
      api_key: "test-key",
      model: "test-model",
      first_byte_timeout: 5000,
      stream_idle_timeout: 5000
    }

    assert Discover.context_limit(config) == {:vllm, 4096}
    assert_received {:discover_url, "http://probe.example.com/olla/models"}
  end
end

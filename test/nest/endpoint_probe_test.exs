defmodule Nest.EndpointProbeTest do
  @moduledoc """
  Tests for the endpoint probe sequence: protocol detection,
  chat base resolution, and `/models` discovery path detection.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.DotConfig
  alias Nest.EndpointProbe

  setup :verify_on_exit!

  defp provider(opts \\ []) do
    %DotConfig.Provider{
      name: Keyword.get(opts, :name, "probe-test"),
      base_url: Keyword.get(opts, :base_url, "https://api.test.com"),
      api_key: Keyword.get(opts, :api_key, "k"),
      protocol: Keyword.get(opts, :protocol, "openai"),
      auto_models: true,
      probe_base_url: Keyword.get(opts, :probe_base_url),
      tags: [],
      models: []
    }
  end

  # Stub Req.get (discovery) and Req.post (chat) to return the given
  # HTTP status based on which probe endpoint the URL matches.
  defp stub_statuses(models: models, chat: chat, messages: messages) do
    test_pid = self()

    Mimic.stub(Req, :get, fn url, _opts ->
      send(test_pid, {:probe, :get, url})
      status_reply(url, "/models", models)
    end)

    Mimic.stub(Req, :post, fn url, _opts ->
      send(test_pid, {:probe, :post, url})

      cond do
        String.ends_with?(url, "/chat/completions") ->
          status_reply(url, "/chat/completions", chat)

        String.ends_with?(url, "/v1/messages") ->
          status_reply(url, "/v1/messages", messages)

        true ->
          {:ok, %{status: 404, body: %{"data" => []}}}
      end
    end)
  end

  defp status_reply(url, suffix, status) do
    body = %{"data" => [%{"id" => String.replace(url, suffix, "") <> "-model"}]}
    {:ok, %{status: status, body: body}}
  end

  describe "naive_structure/1" do
    test "mirrors pre-probe config behaviour" do
      structure = EndpointProbe.naive_structure(provider(base_url: "http://api.test.com/v1"))

      assert structure.protocol == :openai
      assert structure.chat_base_url == "http://api.test.com/v1"
      assert structure.discovery_base_url == "http://api.test.com/v1"
      assert structure.models_path == "/models"
      assert structure.protocol_resolved? == false
      assert structure.discovery_resolved? == false
    end

    test "uses probe-base-url for discovery when set" do
      structure =
        EndpointProbe.naive_structure(
          provider(
            base_url: "http://chat.test.com/v1",
            probe_base_url: "http://probe.test.com/olla"
          )
        )

      assert structure.discovery_base_url == "http://probe.test.com/olla"
    end

    test "respects an explicit anthropic protocol" do
      structure = EndpointProbe.naive_structure(provider(protocol: "anthropic"))
      assert structure.protocol == :anthropic
    end
  end

  describe "probe/1 protocol detection" do
    test "detects an OpenAI-compatible endpoint at a Gemini-style base" do
      base = "https://generativelanguage.test/v1beta/openai"
      p = provider(base_url: base)
      stub_statuses(models: 200, chat: 200, messages: 404)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.protocol == :openai
      assert structure.protocol_resolved? == true
      assert structure.chat_base_url == base
      assert structure.discovery_base_url == base
      assert structure.discovery_resolved? == true
    end

    test "auto-detects an Anthropic endpoint when OpenAI chat is absent" do
      base = "https://api.anthropic.test"
      p = provider(base_url: base)
      stub_statuses(models: 200, chat: 404, messages: 200)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.protocol == :anthropic
      assert structure.chat_base_url == base
    end

    test "trusts an explicitly configured anthropic protocol without probing chat" do
      base = "https://api.deepseek.test/anthropic"
      p = provider(base_url: base, protocol: "anthropic")
      stub_statuses(models: 200, chat: 200, messages: 200)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.protocol == :anthropic
      assert structure.protocol_resolved? == true
      assert structure.chat_base_url == base

      # No chat probe ran for an explicit protocol.
      refute_received {:probe, :post, _}
    end

    test "probes the /v1 chat candidate when the base without /v1 404s" do
      base = "https://api.test.com"
      p = provider(base_url: base)
      test_pid = self()
      # openai: base/chat/completions -> 404, base/v1/chat/completions -> 200
      Mimic.stub(Req, :post, fn url, _opts ->
        send(test_pid, {:probe, :post, url})

        if url == base <> "/v1/chat/completions" do
          {:ok, %{status: 200}}
        else
          {:ok, %{status: 404}}
        end
      end)

      Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 200}} end)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.protocol == :openai
      assert structure.chat_base_url == base <> "/v1"

      expected_base_chat = base <> "/chat/completions"
      expected_v1_chat = base <> "/v1/chat/completions"
      assert_received {:probe, :post, ^expected_base_chat}
      assert_received {:probe, :post, ^expected_v1_chat}
    end
  end

  describe "probe/1 discovery detection" do
    test "resolves discovery when /models returns 200" do
      base = "https://api.test.com/v1"
      p = provider(base_url: base)
      stub_statuses(models: 200, chat: 200, messages: 404)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.discovery_base_url == base
      assert structure.models_path == "/models"
      assert structure.discovery_resolved? == true
    end

    test "resolves discovery at the /v1 path when the base one 404s" do
      base = "https://api.test.com"
      p = provider(base_url: base)
      # Only base/v1/models returns 200.
      Mimic.stub(Req, :get, fn url, _opts ->
        if url == base <> "/v1/models" do
          {:ok, %{status: 200, body: %{"data" => [%{"id" => "m"}]}}}
        else
          {:ok, %{status: 404, body: %{"data" => []}}}
        end
      end)

      Mimic.stub(Req, :post, fn _url, _opts -> {:ok, %{status: 200}} end)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.discovery_base_url == base <> "/v1"
      assert structure.discovery_resolved? == true
    end

    test "treats a 401 as a weak discovery match (route exists behind auth)" do
      base = "https://api.test.com"
      p = provider(base_url: base)
      # Discovery returns 401 everywhere; chat resolves.
      Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 401}} end)
      Mimic.stub(Req, :post, fn _url, _opts -> {:ok, %{status: 200}} end)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.discovery_resolved? == true
      assert structure.protocol_resolved? == true
    end

    test "falls back to the configured base when discovery 404s but chat resolves" do
      base = "https://api.test.com/v1"
      p = provider(base_url: base)
      stub_statuses(models: 404, chat: 200, messages: 404)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.discovery_base_url == base
      assert structure.discovery_resolved? == false
      assert structure.protocol_resolved? == true
    end
  end

  describe "probe/1 protocol inference from discovery body" do
    test "infers OpenAI when chat 404s but discovery is OpenAI-shaped (Gemini quirk)" do
      base = "https://api.gemini.test/v1beta/openai"
      p = provider(base_url: base)

      openai_body = %{
        "data" => [%{"id" => "models/gemini-x", "object" => "model", "owned_by" => "google"}]
      }

      Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 200, body: openai_body}} end)
      Mimic.stub(Req, :post, fn _url, _opts -> {:ok, %{status: 404}} end)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.protocol == :openai
      assert structure.protocol_resolved? == true
      assert structure.chat_base_url == base
      assert structure.discovery_resolved? == true
    end

    test "infers Anthropic from an Anthropic-shaped discovery body" do
      base = "https://api.anthropic.test"
      p = provider(base_url: base)

      anthropic_body = %{
        "data" => [
          %{"type" => "model", "id" => "claude-x", "created_at" => "2024-01-01T00:00:00Z"}
        ]
      }

      Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 200, body: anthropic_body}} end)
      Mimic.stub(Req, :post, fn _url, _opts -> {:ok, %{status: 404}} end)

      assert {:ok, structure} = EndpointProbe.probe(p)
      assert structure.protocol == :anthropic
      assert structure.protocol_resolved? == true
    end
  end

  describe "probe/1 failure modes" do
    test "returns unreachable when nothing responds" do
      p = provider()
      stub_statuses(models: 404, chat: 404, messages: 404)
      assert {:error, :unreachable} = EndpointProbe.probe(p)
    end

    test "returns unreachable on transport errors" do
      p = provider()
      Mimic.stub(Req, :get, fn _url, _opts -> {:error, :nxdomain} end)
      Mimic.stub(Req, :post, fn _url, _opts -> {:error, :nxdomain} end)
      assert {:error, :unreachable} = EndpointProbe.probe(p)
    end

    test "returns unreachable when base_url is nil" do
      assert {:error, :unreachable} = EndpointProbe.probe(provider(base_url: nil))
    end
  end
end

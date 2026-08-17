defmodule Nest.EndpointCacheTest do
  @moduledoc """
  Tests for the endpoint structure cache (ETS-backed, read via
  `get/1`, written via `probe_and_cache/1` / `invalidate/1`).

  `probe_and_cache/1` runs the probe in the caller process (only the
  storage is delegated to the `Nest.EndpointCache` GenServer), so
  plain private-mode `Mimic` stubs apply and this module can be
  `async: true`. Each test uses a distinct base URL, so the shared
  ETS reads/writes never collide.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.DotConfig
  alias Nest.EndpointCache

  setup :verify_on_exit!

  defp provider(opts \\ []) do
    %DotConfig.Provider{
      name: Keyword.get(opts, :name, "cache-test"),
      base_url: Keyword.get(opts, :base_url, "https://api.test.com"),
      api_key: "k",
      protocol: "openai",
      auto_models: true,
      tags: [],
      models: []
    }
  end

  defp stub_resolvable do
    Mimic.stub(Req, :get, fn _url, _opts ->
      {:ok, %{status: 200, body: %{"data" => [%{"id" => "m"}]}}}
    end)

    Mimic.stub(Req, :post, fn _url, _opts -> {:ok, %{status: 200}} end)
  end

  defp stub_unreachable do
    Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: 404}} end)
    Mimic.stub(Req, :post, fn _url, _opts -> {:ok, %{status: 404}} end)
  end

  describe "get/1" do
    test "returns nil for a provider that has not been probed" do
      assert EndpointCache.get(provider()) == nil
    end
  end

  describe "probe_and_cache/1" do
    test "probes, caches, and returns the resolved structure" do
      stub_resolvable()
      p = provider(base_url: "https://resolvable.test.com")

      assert {:ok, structure} = EndpointCache.probe_and_cache(p)
      assert structure.protocol == :openai
      assert EndpointCache.get(p) == structure

      EndpointCache.invalidate(p)
    end

    test "does not cache when the probe fails" do
      stub_unreachable()
      p = provider(base_url: "https://unreachable.test.com")

      assert {:error, :unreachable} = EndpointCache.probe_and_cache(p)
      assert EndpointCache.get(p) == nil
    end
  end

  describe "invalidate/1" do
    test "drops the cached structure" do
      stub_resolvable()
      p = provider(base_url: "https://invalidate.test.com")

      assert {:ok, _structure} = EndpointCache.probe_and_cache(p)
      assert EndpointCache.get(p) != nil

      assert :ok = EndpointCache.invalidate(p)
      assert EndpointCache.get(p) == nil
    end
  end
end

defmodule Nest.DotConfig.WriterTest do
  @moduledoc """
  Tests for `Nest.DotConfig.Writer` (the `local.toml` serializer).
  """
  use ExUnit.Case, async: true

  alias Nest.DotConfig
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer

  defp tmp_file(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{label}_#{System.unique_integer([:positive])}.toml"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  describe "save_providers/2" do
    test "round-trips a provider with models back into a loadable local.toml" do
      path = tmp_file("writer_roundtrip")

      providers = [
        %Provider{
          name: "acme",
          base_url: "https://acme.example/v1",
          api_key: "secret",
          protocol: "openai",
          auto_models: false,
          tags: ["primary"],
          timeout_seconds: 120,
          default_context_limit: 200_000,
          default_thinking_effort: :high,
          probe_base_url: "https://probe.example/v1",
          auto_probe: false,
          models: [
            %Model{
              name: "acme-1",
              provider_name: "acme",
              context_limit: 128_000,
              multi_modal: %{"image" => true},
              thinking_effort: :off
            }
          ]
        }
      ]

      assert :ok = Writer.save_providers(providers, path)
      assert {:ok, config} = DotConfig.load(path)

      provider = config.providers["acme"]
      assert provider.base_url == "https://acme.example/v1"
      assert provider.api_key == "secret"
      assert provider.protocol == "openai"
      assert provider.auto_models == false
      assert provider.tags == ["primary"]
      assert provider.timeout_seconds == 120
      assert provider.default_context_limit == 200_000
      assert provider.default_thinking_effort == :high
      assert provider.probe_base_url == "https://probe.example/v1"
      assert provider.auto_probe == false

      model = provider.models |> List.first()
      assert model.name == "acme-1"
      assert model.context_limit == 128_000
      assert model.multi_modal == %{"image" => true}
      assert model.thinking_effort == :off
    end

    test "omits nil fields so the file stays minimal" do
      path = tmp_file("writer_nils")

      providers = [
        %Provider{name: "bare", base_url: "https://bare.example/v1", models: []}
      ]

      assert :ok = Writer.save_providers(providers, path)
      toml = File.read!(path)

      refute toml =~ "api-key"
      refute toml =~ "timeout"
      refute toml =~ "auto-models"
      refute toml =~ "default-thinking-effort"
      assert toml =~ "base-url"
    end

    test "empty provider list writes an empty providers table" do
      path = tmp_file("writer_empty")
      assert :ok = Writer.save_providers([], path)
      assert {:ok, config} = DotConfig.load(path)
      assert map_size(config.providers) == 0
    end
  end
end

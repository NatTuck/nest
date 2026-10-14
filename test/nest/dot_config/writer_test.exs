defmodule Nest.DotConfig.WriterTest do
  @moduledoc """
  Tests for `Nest.DotConfig.Writer` (the `local.toml` serializer).
  """
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

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

    on_exit(fn -> rm_tmp!(path, label) end)
    path
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

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
          probe_multimodal: true,
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
      assert provider.probe_multimodal == true

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

  describe "write_atomic/2" do
    test "replaces the contents in place, leaving no temp file behind" do
      path = tmp_file("writer_atomic")

      assert :ok = Writer.write_atomic(path, "first")
      assert File.read!(path) == "first"

      assert :ok = Writer.write_atomic(path, "second, longer")
      assert File.read!(path) == "second, longer"

      assert Path.wildcard(path <> ".tmp.*") == []
    end

    test "creates the parent directories it is pointed at" do
      dir = Path.join(System.tmp_dir!(), "writer_nested_#{System.unique_integer([:positive])}")
      path = Path.join([dir, "nested", "local.toml"])

      on_exit(fn -> rm_tmp!(dir, "writer_nested_") end)

      refute File.exists?(dir)

      providers = [%Provider{name: "acme", base_url: "https://acme.example/v1", models: []}]

      assert :ok = Writer.save_providers(providers, path)
      assert {:ok, config} = DotConfig.load(path)
      assert config.providers["acme"].base_url == "https://acme.example/v1"
    end

    test "reports a write that cannot land, and leaves nothing behind" do
      dir =
        Path.join(System.tmp_dir!(), "writer_unwritable_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "local.toml")

      on_exit(fn ->
        # The write is expected to fail because the directory was made
        # unwritable; cleanup has to be able to empty it either way.
        File.chmod(dir, 0o700)
        rm_tmp!(dir, "writer_unwritable_")
      end)

      File.chmod!(dir, 0o500)

      assert {:error, reason} = Writer.write_atomic(path, "nope")
      assert reason in [:eacces, :eperm]

      File.chmod!(dir, 0o700)
      refute File.exists?(path)
      assert Path.wildcard(path <> ".tmp.*") == []
    end

    test "creates the file 0600, and tightens an existing wider one" do
      path = tmp_file("writer_mode")
      providers = [%Provider{name: "acme", base_url: "https://acme.example/v1", models: []}]

      assert :ok = Writer.save_providers(providers, path)
      assert mode(path) == 0o600

      File.chmod!(path, 0o644)
      assert :ok = Writer.save_providers(providers, path)
      assert mode(path) == 0o600
    end

    test "names its temp file with a counter and random bytes" do
      path = tmp_file("writer_tmpname")

      names = for _ <- 1..25, do: Writer.tmp_path(path)

      assert Enum.uniq(names) == names
      assert Enum.all?(names, &Regex.match?(~r/\.tmp\.\d+\.[0-9a-f]{8}$/, &1))
    end
  end
end

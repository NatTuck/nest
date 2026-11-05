defmodule Nest.DotConfig.WriterTest do
  @moduledoc """
  Tests for `Nest.DotConfig.Writer` (the `local.toml` serializer).
  """
  use ExUnit.Case, async: true

  import Nest.Test.FileMode
  import Nest.Test.TmpCleanup

  alias Nest.DotConfig
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer

  # `save_providers/2` records the providers a payload drops by reading
  # `DotConfig.config_file/0`, which in `:test` is `test/data/config.toml` — the
  # three-provider fixture. Unstubbed, every file written here would carry
  # `deleted-providers = [those three]`: invisible, and load-bearing (the
  # parse-cache test needs two saves to serialize to the same length). A path
  # that does not exist is the "no base config" case, where nothing can come
  # back and so nothing is recorded.
  setup do
    base =
      Path.join(System.tmp_dir!(), "no_base_#{System.unique_integer([:positive])}.toml")

    Mimic.stub(DotConfig, :config_file, fn -> base end)
    :ok
  end

  defp tmp_file(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{label}_#{System.unique_integer([:positive])}.toml"
      )

    on_exit(fn -> rm_tmp!(path, label) end)
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
          first_byte_timeout_seconds: 120,
          stream_idle_timeout_seconds: 45,
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
      assert provider.first_byte_timeout_seconds == 120
      assert provider.stream_idle_timeout_seconds == 45
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

      # One representative of the "nil value is omitted" clause, which every
      # nil field here goes through, plus the nil-effort clause it does not:
      # `effort_to_string(nil)` has to collapse to nil, or the file would carry
      # `default-thinking-effort = "nil"` and fail to load.
      refute toml =~ "api-key"
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

  describe "the api key is write-only (#202)" do
    test "a kept key is written back from the overlay, reference and all" do
      path = tmp_file("writer_key_keep")
      key_file = Path.join(System.tmp_dir!(), "nest-tmp-writer-key")
      File.write!(key_file, "resolved-from-file\n")
      on_exit(fn -> File.rm(key_file) end)

      # The overlay as the app itself writes it: a `file:` reference. Loading it
      # resolves the reference for the provider but leaves the reference in the
      # struct, which is what a keep has to write back.
      File.write!(path, """
      [providers.acme]
      api-key = "file:#{key_file}"
      """)

      assert :ok =
               Writer.save_providers([%Provider{name: "acme", api_key_action: :keep}], path)

      # Verbatim. Writing the resolved secret would put it on disk and break the
      # reference the operator wrote.
      assert File.read!(path) =~ ~s(api-key = "file:#{key_file}")
      refute File.read!(path) =~ "resolved-from-file"
    end

    test "a kept key the overlay does not hold writes no line, so the base's still applies" do
      path = tmp_file("writer_key_absent")

      assert :ok =
               Writer.save_providers([%Provider{name: "acme", api_key_action: :keep}], path)

      # Absent, not empty: `api-key = ""` would shadow a key `config.toml`
      # defines with nothing, which is a clear rather than a keep.
      refute File.read!(path) =~ "api-key"
    end

    test "a set key replaces the stored one" do
      path = tmp_file("writer_key_set")
      File.write!(path, "[providers.acme]\napi-key = \"stored\"\n")

      assert :ok =
               Writer.save_providers(
                 [%Provider{name: "acme", api_key: "typed", api_key_action: :set}],
                 path
               )

      toml = File.read!(path)
      assert toml =~ ~s(api-key = "typed")
      refute toml =~ "stored"
    end

    test "a cleared key writes an empty line, which is what shadows the base's" do
      path = tmp_file("writer_key_clear")
      File.write!(path, "[providers.acme]\napi-key = \"stored\"\n")

      assert :ok = Writer.save_providers([%Provider{name: "acme", api_key_action: :clear}], path)

      # Explicit, not omitted: the overlay's own line is what stops the base's
      # key from applying.
      assert File.read!(path) =~ ~s(api-key = "")

      assert {:ok, config} = DotConfig.load(path)
      assert config.providers["acme"].api_key == ""
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
      # The nested file is loadable: the mkdir_p branch is what is under test
      # here, the per-field round-trip is the first test's job.
      assert {:ok, _config} = DotConfig.load(path)
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
  end
end

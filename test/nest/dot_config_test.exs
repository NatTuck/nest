defmodule Nest.DotConfigTest do
  @moduledoc """
  Tests for the DotConfig module.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.DotConfig

  describe "load/0" do
    test "loads the test config with providers, a flat models map, and lobby-channel entries" do
      assert {:ok, config} = DotConfig.load()

      # Verify providers are loaded
      assert is_map(config.providers)
      assert "pegasus" in Map.keys(config.providers)
      assert "model-studio" in Map.keys(config.providers)

      # Verify pegasus provider has auto-models enabled
      pegasus = config.providers["pegasus"]
      assert pegasus.auto_models == true
      assert pegasus.base_url == "http://pegasus:8080/v1"

      # Verify model-studio provider
      model_studio = config.providers["model-studio"]
      assert model_studio.auto_models == false
      assert model_studio.base_url == "https://coding-intl.dashscope.aliyuncs.com/v1"

      # Should have models from model-studio (pegasus has auto-models but no explicit models)
      assert is_map(config.models)

      # Verify specific models exist
      assert "qwen3.5-plus" in Map.keys(config.models)
      assert "MiniMax-M2.5" in Map.keys(config.models)

      # Verify model structure
      qwen = config.models["qwen3.5-plus"]
      assert qwen.name == "qwen3.5-plus"
      assert qwen.provider_name == "model-studio"
      assert qwen.context_limit == 512_000

      minimax = config.models["MiniMax-M2.5"]
      assert minimax.name == "MiniMax-M2.5"
      assert minimax.provider_name == "model-studio"
      assert minimax.context_limit == nil

      # Simulate what lobby_channel does
      models_list =
        config.models
        |> Map.values()
        |> Enum.map(fn model ->
          %{
            "name" => model.name,
            "provider" => model.provider_name,
            "context_limit" => model.context_limit
          }
        end)

      # Verify structure (6 models: 2 from model-studio + 2 from anthropic-provider + 2 from pegasus)
      assert length(models_list) == 6

      # All models should have string keys (for JSON serialization)
      Enum.each(models_list, fn model ->
        assert is_map(model)
        assert Map.has_key?(model, "name")
        assert Map.has_key?(model, "provider")
        assert Map.has_key?(model, "context_limit")
        assert is_binary(model["name"])
        assert is_binary(model["provider"])
      end)

      # Verify specific model
      lobby_qwen = Enum.find(models_list, fn m -> m["name"] == "qwen3.5-plus" end)
      assert lobby_qwen["provider"] == "model-studio"
      assert lobby_qwen["context_limit"] == 512_000
    end
  end

  describe "load/1" do
    test "loads config from specific file path" do
      config_path = Path.join([File.cwd!(), "test", "data", "config.toml"])
      assert {:ok, config} = DotConfig.load(config_path)

      assert is_map(config.providers)
      assert "model-studio" in Map.keys(config.providers)
    end

    test "returns error for non-existent file" do
      assert {:error, _} = DotConfig.load("/nonexistent/path/config.toml")
    end
  end

  describe "provider silence bounds" do
    test "defaults both bounds, and reads the legacy `timeout` as the first-byte bound" do
      {:ok, config} = DotConfig.load()

      # No key at all: both defaults.
      model_studio = config.providers["model-studio"]
      assert model_studio.first_byte_timeout_seconds == 900
      assert model_studio.stream_idle_timeout_seconds == 120

      # The pre-split `timeout` key keeps its meaning — "the prefill may take
      # this long" — and does *not* become the idle bound: an existing
      # `timeout = 600` must not make every dead connection take ten minutes to
      # notice.
      pegasus = config.providers["pegasus"]
      assert pegasus.first_byte_timeout_seconds == 60
      assert pegasus.stream_idle_timeout_seconds == 120

      anthropic = config.providers["anthropic-provider"]
      assert anthropic.first_byte_timeout_seconds == 600
      assert anthropic.stream_idle_timeout_seconds == 120
    end

    test "parses both keys, and first_byte_timeout wins over the legacy timeout" do
      toml = """
      [providers.both]
      base-url = "http://example.com/v1"
      api-key = "x"
      timeout = 60
      first_byte_timeout = 900
      stream_idle_timeout = 15
      """

      log =
        capture_log(fn ->
          {:ok, config} = DotConfig.load(write_toml!(toml, "silence_bounds"))
          provider = config.providers["both"]

          assert provider.first_byte_timeout_seconds == 900
          assert provider.stream_idle_timeout_seconds == 15
        end)

      # Both keys is ambiguous, and preferring the new one silently left a
      # `timeout = 60` in the file looking live. The warning names the provider,
      # the key in force and the value it ignored.
      assert log =~ "Provider both"
      assert log =~ "`timeout` (60)"
      assert log =~ "`first_byte_timeout` (900s) are set"
      assert log =~ "`first_byte_timeout` is in force"
      assert log =~ "`timeout` is ignored"
    end

    test "raises on an invalid bound, naming the key" do
      # Both keys are validated by the same rule (`ModelValidation.validate_timeout/3`),
      # and the message names the key because there are two of them now.
      for {key, value, field} <- [
            {"timeout", "0", "timeout"},
            {"timeout", ~s("300"), "timeout"},
            {"first_byte_timeout", "0", "first_byte_timeout"},
            {"first_byte_timeout", ~s("900"), "first_byte_timeout"},
            {"stream_idle_timeout", "-1", "stream_idle_timeout"},
            {"stream_idle_timeout", "1.5", "stream_idle_timeout"}
          ] do
        toml = """
        [providers.bad]
        base-url = "http://example.com/v1"
        api-key = "x"
        #{key} = #{value}
        """

        path = write_toml!(toml, "bad_#{key}")

        assert_raise RuntimeError, ~r/invalid #{field}/, fn ->
          DotConfig.load(path)
        end
      end
    end
  end

  describe "provider default-context-limit" do
    test "parses the configured value when present and is nil for providers that don't set it" do
      {:ok, config} = DotConfig.load()
      assert config.providers["pegasus"].default_context_limit == 512_000
      assert config.providers["model-studio"].default_context_limit == nil
      assert config.providers["anthropic-provider"].default_context_limit == nil
    end

    test "is nil when absent from a TOML with only a provider block" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "no_default_limit_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].default_context_limit == nil
    end

    test "raises on invalid (non-positive-integer) value" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      default-context-limit = 0
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "bad_default_limit_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid default-context-limit/, fn ->
        DotConfig.load(tmp_path)
      end
    end

    test "raises on non-integer value" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      default-context-limit = "200000"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "bad_default_limit_str_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid default-context-limit/, fn ->
        DotConfig.load(tmp_path)
      end
    end
  end

  describe "provider probe-base-url" do
    test "is set for the fixture provider and nil for providers that don't set it" do
      {:ok, config} = DotConfig.load()
      assert config.providers["pegasus"].probe_base_url == "http://pegasus-probe.local/olla"
      assert config.providers["model-studio"].probe_base_url == nil
      assert config.providers["anthropic-provider"].probe_base_url == nil
    end

    test "parses the configured value when present" do
      toml = """
      [providers.foo]
      base-url = "http://chat.example.com/v1"
      probe-base-url = "http://probe.example.com/v1"
      api-key = "x"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "probe_url_set_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].probe_base_url == "http://probe.example.com/v1"
    end

    test "is nil when absent from a TOML with only a provider block" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "no_probe_url_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].probe_base_url == nil
    end

    test "raises on empty-string probe-base-url" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      probe-base-url = ""
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "empty_probe_url_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid probe-base-url/, fn ->
        DotConfig.load(tmp_path)
      end
    end

    test "raises on non-string probe-base-url" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      probe-base-url = 42
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "non_string_probe_url_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid probe-base-url/, fn ->
        DotConfig.load(tmp_path)
      end
    end
  end

  describe "provider auto-probe" do
    test "defaults to true when absent" do
      {:ok, config} = DotConfig.load()
      assert config.providers["model-studio"].auto_probe == true
    end

    test "parses an explicit value" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      auto-probe = false
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "auto_probe_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].auto_probe == false
    end

    test "raises on a non-boolean value" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      auto-probe = "yes"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "auto_probe_bad_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid auto-probe/, fn ->
        DotConfig.load(tmp_path)
      end
    end
  end

  describe "provider expose-models" do
    test "defaults to false when absent" do
      {:ok, config} = DotConfig.load()
      assert config.providers["model-studio"].expose_models == false
    end

    test "parses an explicit value" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      expose-models = true
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "expose_models_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].expose_models == true
    end

    test "raises on a non-boolean value" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      expose-models = "yes"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "expose_models_bad_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid expose-models/, fn ->
        DotConfig.load(tmp_path)
      end
    end
  end

  describe "max-tool-iterations" do
    test "parses the configured value from the test data file" do
      assert {:ok, config} = DotConfig.load()
      assert config.max_tool_iterations == 5
      assert DotConfig.max_tool_iterations(config) == 5
    end

    test "is nil when absent from the TOML" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "no_max_iter_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert {:ok, config} = DotConfig.load(tmp_path)
      assert config.max_tool_iterations == nil
      assert DotConfig.max_tool_iterations(config) == nil
    end

    test "default_max_tool_iterations/0 returns the hardcoded fallback" do
      assert DotConfig.default_max_tool_iterations() == 99
    end

    test "raises on non-positive-integer value" do
      bad_toml = """
      max-tool-iterations = 0
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "bad_max_iter_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/Invalid max-tool-iterations/, fn ->
        DotConfig.load(tmp_path)
      end
    end

    test "raises on non-integer value" do
      bad_toml = """
      max-tool-iterations = "25"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "bad_max_iter_str_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/Invalid max-tool-iterations/, fn ->
        DotConfig.load(tmp_path)
      end
    end
  end

  describe "thinking-effort" do
    defp write_toml!(toml, label) do
      path =
        Path.join(
          System.tmp_dir!(),
          "#{label}_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(path, toml)
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "parses the top-level global default and falls back to :medium" do
      assert DotConfig.default_thinking_effort() == :medium

      toml = """
      default-thinking-effort = "low"
      """

      {:ok, config} = DotConfig.load(write_toml!(toml, "global_thinking"))
      assert DotConfig.default_thinking_effort(config) == :low
    end

    test "parses per-provider and per-model thinking-effort" do
      toml = """
      [providers.pegasus]
      base-url = "http://example.com/v1"
      api-key = "x"
      default-thinking-effort = "high"

      [[providers.pegasus.models]]
      name = "pegasus-mini"
      thinking-effort = "off"
      """

      {:ok, config} = DotConfig.load(write_toml!(toml, "provider_model_thinking"))
      assert config.providers["pegasus"].default_thinking_effort == :high
      assert config.models["pegasus-mini"].thinking_effort == :off
    end

    test "raises on an unknown thinking-effort value" do
      toml = """
      default-thinking-effort = "turbo"
      """

      assert_raise RuntimeError, ~r/Invalid thinking-effort/, fn ->
        DotConfig.load(write_toml!(toml, "bad_thinking"))
      end
    end
  end
end

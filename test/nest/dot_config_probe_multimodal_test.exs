defmodule Nest.DotConfig.ProbeMultimodalTest do
  @moduledoc """
  Tests for the `probe-multimodal` provider opt-in parsing, split out of
  `dot_config_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Nest.DotConfig

  describe "provider probe-multimodal" do
    test "defaults to false when absent" do
      {:ok, config} = DotConfig.load()
      assert config.providers["model-studio"].probe_multimodal == false
    end

    test "parses an explicit value" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      probe-multimodal = true
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "probe_multimodal_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].probe_multimodal == true
    end

    test "parses an explicit false, which is not the same as absent" do
      toml = """
      [providers.foo]
      base-url = "http://example.com/v1"
      api-key = "x"
      probe-multimodal = false
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "probe_multimodal_false_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, config} = DotConfig.load(tmp_path)
      assert config.providers["foo"].probe_multimodal == false
    end

    test "raises on a non-boolean value" do
      bad_toml = """
      [providers.bad]
      base-url = "http://example.com/v1"
      api-key = "x"
      probe-multimodal = "yes"
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "probe_multimodal_bad_#{System.unique_integer([:positive])}.toml"
        )

      File.write!(tmp_path, bad_toml)
      on_exit(fn -> File.rm(tmp_path) end)

      assert_raise RuntimeError, ~r/invalid probe-multimodal/, fn ->
        DotConfig.load(tmp_path)
      end
    end
  end
end

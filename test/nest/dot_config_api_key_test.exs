defmodule Nest.DotConfig.ApiKeyTest do
  @moduledoc """
  Provider `api-key` reference validation at config-load time
  (`Nest.DotConfig.KeyValidation`), split out of `dot_config_test.exs`.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.DotConfig

  setup :verify_on_exit!

  describe "provider api-key validation at load" do
    # `load/0` resolves every provider's `api-key` once, at load time, so
    # an unresolvable reference names the provider instead of crashing
    # whichever code path (chat, discovery, probe) touches it first.
    # `local.toml` is where the app's own editor writes providers, so the
    # overlay is stubbed to a temp file — the idiom
    # `lobby_channel/providers_test.exs` uses.
    defp load_with_overlay(toml) do
      path =
        Path.join(
          System.tmp_dir!(),
          "nest-tmp-api-key-#{System.unique_integer([:positive])}.toml"
        )

      File.write!(path, toml)
      on_exit(fn -> File.rm(path) end)
      Mimic.stub(DotConfig, :local_file, fn -> path end)
      DotConfig.load()
    end

    test "raises naming the provider when a key reference cannot be resolved" do
      # The variable is set nowhere and the file does not exist, so both
      # references are unresolvable in every environment this runs in.
      System.delete_env("NEST_TEST_DEFINITELY_UNSET_API_KEY")

      env_error =
        assert_raise RuntimeError, fn ->
          load_with_overlay("""
          [providers.env-key]
          base-url = "http://api.test.com/v1"
          api-key = "${NEST_TEST_DEFINITELY_UNSET_API_KEY}"
          """)
        end

      assert env_error.message =~ "Provider env-key: cannot resolve api-key"
      assert env_error.message =~ "NEST_TEST_DEFINITELY_UNSET_API_KEY"
      assert env_error.message =~ "not set"

      file_error =
        assert_raise RuntimeError, fn ->
          load_with_overlay("""
          [providers.file-key]
          base-url = "http://api.test.com/v1"
          api-key = "file:/nonexistent/nest-tmp-api-key"
          """)
        end

      assert file_error.message =~ "Provider file-key: cannot resolve api-key"
      assert file_error.message =~ "Failed to read API key file"
    end

    test "accepts a literal, an empty, and an absent key" do
      assert {:ok, config} =
               load_with_overlay("""
               [providers.none-key]
               base-url = "http://api.test.com/v1"
               api-key = "none"

               [providers.blank-key]
               base-url = "http://api.test.com/v1"
               api-key = ""

               [providers.absent-key]
               base-url = "http://api.test.com/v1"
               """)

      assert config.providers["none-key"].api_key == "none"
      assert config.providers["blank-key"].api_key == ""
      assert config.providers["absent-key"].api_key == nil
    end
  end
end

defmodule Nest.DotConfigTest do
  @moduledoc """
  Tests for the DotConfig module.
  """
  use ExUnit.Case

  alias Nest.DotConfig

  describe "load/0" do
    test "loads config from test/data/config.toml in test environment" do
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
    end

    test "returns flat models map with correct structure" do
      assert {:ok, config} = DotConfig.load()

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
    end

    test "returns model names suitable for lobby channel" do
      assert {:ok, config} = DotConfig.load()

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

      # Verify structure
      assert length(models_list) == 2

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
      qwen = Enum.find(models_list, fn m -> m["name"] == "qwen3.5-plus" end)
      assert qwen["provider"] == "model-studio"
      assert qwen["context_limit"] == 512_000
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
end

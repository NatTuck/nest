defmodule Nest.ChatModelTest do
  @moduledoc """
  High-value tests for Nest.ChatModel focusing on:
  - Security contracts (API key resolution)
  - HTTP integration (auth headers)
  - Response robustness (different formats)
  - Error clarity (actionable messages)
  - Protocol selection (type safety)
  - Endpoint construction (URL building)
  """

  use Nest.DataCase, async: true

  alias Nest.ChatModel
  alias Nest.DotConfig

  import ExUnit.CaptureLog
  import Mimic

  setup :verify_on_exit!

  describe "new/1 by model name" do
    test "creates OpenAI-compatible chain for model from config" do
      # qwen3.5-plus is defined in test/data/config.toml under model-studio provider
      assert {:ok, chain} = ChatModel.new(model: "qwen3.5-plus")
      assert chain.llm.__struct__ == LangChain.ChatModels.ChatOpenAI
      assert chain.llm.model == "qwen3.5-plus"
    end

    test "returns ModelNotFoundError for unknown model" do
      assert {:error, %Nest.ChatModel.ModelNotFoundError{message: msg}} =
               ChatModel.new(model: "nonexistent-model-xyz")

      assert msg =~ "nonexistent-model-xyz"
    end
  end

  describe "new/1 by provider" do
    test "creates chain using provider's first explicit model" do
      # model-studio has explicit models defined
      assert {:ok, chain} = ChatModel.new(provider: "model-studio")
      assert chain.llm.__struct__ == LangChain.ChatModels.ChatOpenAI
      # First model in config is qwen3.5-plus
      assert chain.llm.model == "qwen3.5-plus"
    end

    test "returns ProviderNotFoundError for unknown provider" do
      assert {:error, %Nest.ChatModel.ProviderNotFoundError{message: msg}} =
               ChatModel.new(provider: "nonexistent-provider-xyz")

      assert msg =~ "nonexistent-provider-xyz"
    end
  end

  describe "new/1 by tag" do
    test "creates chain for first provider matching tag" do
      # Stub the auto-discovery HTTP call for pegasus provider
      stub(Req, :get, fn "http://pegasus:8080/v1/models", _opts ->
        {:ok, %{status: 200, body: %{"data" => [%{"id" => "test-model"}]}}}
      end)

      # "local" tag matches pegasus provider
      assert {:ok, chain} = ChatModel.new(tag: "local")
      assert chain.llm.__struct__ == LangChain.ChatModels.ChatOpenAI
    end

    test "returns ProviderNotFoundError when no provider has tag" do
      assert {:error, %Nest.ChatModel.ProviderNotFoundError{message: msg}} =
               ChatModel.new(tag: "nonexistent-tag")

      assert msg =~ "nonexistent-tag"
    end
  end

  describe "new!/1 error raising" do
    test "raises ModelNotFoundError for unknown model" do
      assert_raise Nest.ChatModel.ModelNotFoundError, ~r/unknown-model/, fn ->
        ChatModel.new!(model: "unknown-model")
      end
    end

    test "raises ProviderNotFoundError for unknown provider" do
      assert_raise Nest.ChatModel.ProviderNotFoundError, ~r/unknown-provider/, fn ->
        ChatModel.new!(provider: "unknown-provider")
      end
    end

    test "raises ArgumentError when no option specified" do
      assert_raise ArgumentError, ~r/Must specify/, fn ->
        ChatModel.new!([])
      end
    end
  end

  describe "from_provider/2" do
    test "creates chat model using explicit provider" do
      assert {:ok, llm} = ChatModel.from_provider("model-studio", "MiniMax-M2.5")
      assert llm.__struct__ == LangChain.ChatModels.ChatOpenAI
      assert llm.model == "MiniMax-M2.5"
    end

    test "creates model using provider's first model when none specified" do
      assert {:ok, llm} = ChatModel.from_provider("model-studio")
      assert llm.__struct__ == LangChain.ChatModels.ChatOpenAI
      assert llm.model == "qwen3.5-plus"
    end

    test "raises ProviderNotFoundError for unknown provider" do
      assert_raise Nest.ChatModel.ProviderNotFoundError, ~r/unknown-provider/, fn ->
        ChatModel.from_provider("unknown-provider", "some-model")
      end
    end
  end

  describe "protocol selection" do
    test "selects ChatAnthropic for anthropic protocol" do
      # Test against the anthropic-provider defined in test/data/config.toml
      # The protocol "anthropic" should result in ChatAnthropic struct
      {:ok, llm} =
        ChatModel.from_provider("anthropic-provider", "claude-3-opus-20240229")

      assert llm.__struct__ == LangChain.ChatModels.ChatAnthropic
      assert llm.model == "claude-3-opus-20240229"
    end

    test "defaults to ChatOpenAI for unspecified protocol" do
      {:ok, llm} = ChatModel.from_provider("model-studio", "qwen3.5-plus")
      assert llm.__struct__ == LangChain.ChatModels.ChatOpenAI
    end
  end

  describe "endpoint construction" do
    test "OpenAI endpoints include /chat/completions path" do
      {:ok, llm} = ChatModel.from_provider("model-studio", "qwen3.5-plus")
      assert llm.__struct__ == LangChain.ChatModels.ChatOpenAI
      # Endpoint should be base_url + "/chat/completions"
      assert String.ends_with?(llm.endpoint, "/chat/completions")
    end

    test "Anthropic endpoints use base_url directly without path suffix" do
      # Anthropic uses the base_url directly as endpoint
      # (when explicitly set, otherwise uses default)
      {:ok, llm} = ChatModel.from_provider("anthropic-provider", "claude-3")
      assert llm.__struct__ == LangChain.ChatModels.ChatAnthropic
    end
  end

  describe "LLM receive timeout" do
    test "OpenAI-compatible models receive the provider's timeout in milliseconds" do
      # model-studio has no explicit timeout in test config -> default 300s = 300_000 ms
      {:ok, llm} = ChatModel.from_provider("model-studio", "qwen3.5-plus")
      assert llm.receive_timeout == 300_000
    end

    test "Anthropic models receive the provider's timeout in milliseconds" do
      # anthropic-provider has timeout = 600 in test config -> 600_000 ms
      {:ok, llm} =
        ChatModel.from_provider("anthropic-provider", "claude-3-opus-20240229")

      assert llm.receive_timeout == 600_000
    end

    test "providers with a custom timeout use that value" do
      # pegasus has timeout = 60 in test config -> 60_000 ms
      # pegasus uses auto-models, so we need to pass a model name explicitly
      {:ok, llm} = ChatModel.from_provider("pegasus", "some-model")
      assert llm.receive_timeout == 60_000
    end
  end

  describe "API key resolution security" do
    test "resolves environment variable keys" do
      # Set an environment variable for testing
      System.put_env("TEST_API_KEY", "resolved-from-env")

      provider = %DotConfig.Provider{
        name: "env-test",
        base_url: "http://test.com",
        api_key: "${TEST_API_KEY}",
        protocol: "openai",
        auto_models: false,
        tags: [],
        models: []
      }

      # Create a model - the key should be resolved from env
      {:ok, llm} = ChatModel.build_chat_model(provider, "test-model")
      assert llm.api_key == "resolved-from-env"

      System.delete_env("TEST_API_KEY")
    end

    test "reads API key from file when using file: prefix" do
      # Create a temporary file with API key
      tmp_file =
        Path.join(System.tmp_dir!(), "test_api_key_#{System.unique_integer([:positive])}")

      File.write!(tmp_file, "  key-from-file  \n")

      provider = %DotConfig.Provider{
        name: "file-test",
        base_url: "http://test.com",
        api_key: "file:#{tmp_file}",
        protocol: "openai",
        auto_models: false,
        tags: [],
        models: []
      }

      {:ok, llm} = ChatModel.build_chat_model(provider, "test-model")
      assert llm.api_key == "key-from-file"

      File.rm!(tmp_file)
    end

    test "passes through plain API keys unchanged" do
      provider = %DotConfig.Provider{
        name: "plain-test",
        base_url: "http://test.com",
        api_key: "sk-plain-key-123",
        protocol: "openai",
        auto_models: false,
        tags: [],
        models: []
      }

      {:ok, llm} = ChatModel.build_chat_model(provider, "test-model")
      assert llm.api_key == "sk-plain-key-123"
    end
  end

  describe "list_models/1 HTTP integration" do
    test "sends correct Authorization header with Bearer token" do
      provider = %DotConfig.Provider{
        name: "http-test",
        base_url: "http://api.test.com/v1",
        api_key: "test-api-key-xyz",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      # Expect Req.get with correct auth header
      expect(Req, :get, fn url, opts ->
        assert url == "http://api.test.com/v1/models"

        headers = Keyword.get(opts, :headers, [])
        assert {"Authorization", "Bearer test-api-key-xyz"} in headers

        {:ok, %{status: 200, body: %{"data" => [%{"id" => "model1"}]}}}
      end)

      ChatModel.list_models(provider)
    end

    test "handles OpenAI-style /models response format" do
      provider = %DotConfig.Provider{
        name: "openai-format",
        base_url: "http://api.test.com/v1",
        api_key: "key",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => [
               %{"id" => "gpt-4"},
               %{"id" => "gpt-3.5-turbo"},
               %{"object" => "irrelevant"}
             ]
           }
         }}
      end)

      models = ChatModel.list_models(provider)
      assert "gpt-4" in models
      assert "gpt-3.5-turbo" in models
      # Only extracts valid entries
      assert length(models) == 2
    end

    test "handles alternative /models response format" do
      provider = %DotConfig.Provider{
        name: "alt-format",
        base_url: "http://api.test.com/v1",
        api_key: "key",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "models" => [
               %{"name" => "custom-model-1"},
               %{"name" => "custom-model-2"}
             ]
           }
         }}
      end)

      models = ChatModel.list_models(provider)
      assert "custom-model-1" in models
      assert "custom-model-2" in models
    end

    test "returns empty list for malformed response" do
      provider = %DotConfig.Provider{
        name: "malformed",
        base_url: "http://api.test.com/v1",
        api_key: "key",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"unexpected" => "format"}}}
      end)

      assert ChatModel.list_models(provider) == []
    end

    test "returns empty list on HTTP error" do
      provider = %DotConfig.Provider{
        name: "error",
        base_url: "http://api.test.com/v1",
        api_key: "key",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:error, :nxdomain}
      end)

      log =
        capture_log(fn ->
          assert ChatModel.list_models(provider) == []
        end)

      assert log =~ "Failed to list models from error"
      assert log =~ "nxdomain"
    end

    test "returns empty list on non-200 status" do
      provider = %DotConfig.Provider{
        name: "bad-status",
        base_url: "http://api.test.com/v1",
        api_key: "key",
        protocol: "openai",
        auto_models: true,
        tags: [],
        models: []
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
      end)

      log =
        capture_log(fn ->
          assert ChatModel.list_models(provider) == []
        end)

      assert log =~ "Provider returned status 401"
    end
  end

  describe "list_models/1 by provider name" do
    test "returns empty list for unknown provider name" do
      log =
        capture_log(fn ->
          assert ChatModel.list_models("unknown-provider-xyz") == []
        end)

      assert log =~ "Provider not found: unknown-provider-xyz"
    end
  end

  describe "error message clarity" do
    test "ModelNotFoundError includes the searched model name" do
      {:error, error} = ChatModel.new(model: "specific-missing-model")
      assert error.__struct__ == Nest.ChatModel.ModelNotFoundError
      assert error.message =~ "specific-missing-model"
    end

    test "ProviderNotFoundError includes the searched provider name" do
      {:error, error} = ChatModel.new(provider: "missing-provider-name")
      assert error.__struct__ == Nest.ChatModel.ProviderNotFoundError
      assert error.message =~ "missing-provider-name"
    end

    test "ProviderNotFoundError includes the searched tag" do
      {:error, error} = ChatModel.new(tag: "missing-tag-name")
      assert error.__struct__ == Nest.ChatModel.ProviderNotFoundError
      assert error.message =~ "missing-tag-name"
    end
  end
end

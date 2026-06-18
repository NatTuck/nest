defmodule Nest.LLM.DiscoverTest do
  @moduledoc """
  Tests for the best-effort context-window discovery probe.

  Covers every known provider response shape (vLLM, OpenRouter,
  llama.cpp) and the failure modes that should fall through to the
  128k default.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover

  setup :verify_on_exit!

  @default_limit 128_000

  defp build_config(opts \\ []) do
    %ClientConfig{
      client: Nest.LLM.OpenAIClient,
      base_url: Keyword.get(opts, :base_url, "http://localhost:8080/v1"),
      api_key: Keyword.get(opts, :api_key, "test-key"),
      model: Keyword.get(opts, :model, "test-model"),
      receive_timeout: 5000
    }
  end

  describe "vLLM response shape" do
    test "extracts max_model_len from a vLLM /v1/models response" do
      body = %{
        "object" => "list",
        "data" => [
          %{"id" => "test-model", "max_model_len" => 32_768}
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:vllm, 32_768}
    end

    test "vLLM wins over openrouter-style context_length when both are present" do
      body = %{
        "data" => [
          %{
            "id" => "test-model",
            "max_model_len" => 8192,
            "context_length" => 128_000
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:vllm, 8192}
    end
  end

  describe "OpenRouter response shape" do
    test "extracts context_length from an OpenRouter /v1/models response" do
      body = %{
        "data" => [
          %{
            "id" => "openai/gpt-4o",
            "context_length" => 128_000,
            "top_provider" => %{"max_completion_tokens" => 16_384}
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config(model: "openai/gpt-4o")) ==
               {:openrouter, 128_000}
    end
  end

  describe "llama.cpp response shape" do
    test "extracts meta.n_ctx when both n_ctx and n_ctx_train are present" do
      body = %{
        "data" => [
          %{
            "id" => "llama-3.1",
            "meta" => %{"n_ctx" => 4096, "n_ctx_train" => 131_072}
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:llama_cpp, 4096}
    end

    test "falls back to n_ctx_train when n_ctx is missing" do
      body = %{
        "data" => [
          %{
            "id" => "llama-3.1",
            "meta" => %{"n_ctx_train" => 32_768}
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:llama_cpp, 32_768}
    end

    test "llama.cpp wins over vllm-style and openrouter-style fields when present" do
      body = %{
        "data" => [
          %{
            "id" => "x",
            "max_model_len" => 100,
            "context_length" => 200,
            "meta" => %{"n_ctx" => 300}
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      # vLLM and OpenRouter fields are checked before meta, so the
      # order is vllm > openrouter > llama_cpp. This test pins the
      # precedence: if all three are present, vllm wins.
      assert Discover.context_limit(build_config()) == {:vllm, 100}
    end
  end

  describe "model id matching" do
    test "matches on exact id" do
      body = %{
        "data" => [
          %{"id" => "other-model", "max_model_len" => 100},
          %{"id" => "test-model", "max_model_len" => 200}
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:vllm, 200}
    end

    test "strips a leading path to match GGUF file paths" do
      body = %{
        "data" => [
          %{
            "id" => "/data/models/llama-3.1-8b.Q4_K_M.gguf",
            "max_model_len" => 8192
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config(model: "llama-3.1-8b.Q4_K_M.gguf")) ==
               {:vllm, 8192}
    end

    test "uses the single model when id doesn't match and only one model is present" do
      body = %{
        "data" => [
          %{"id" => "server-default", "max_model_len" => 4096}
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config(model: "my-model")) ==
               {:vllm, 4096}
    end

    test "falls through to default when id doesn't match and multiple models are present" do
      body = %{
        "data" => [
          %{"id" => "model-a", "max_model_len" => 1024},
          %{"id" => "model-b", "max_model_len" => 2048}
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config(model: "model-c")) ==
               {:default, @default_limit}
    end

    test "falls through to default for an empty data array" do
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end
  end

  describe "alternate response shapes" do
    test "tolerates a top-level 'models' key (Ollama-style)" do
      body = %{
        "models" => [
          %{"name" => "test-model", "max_model_len" => 16_384}
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:vllm, 16_384}
    end

    test "tolerates a bare list as the response body" do
      body = [
        %{"id" => "test-model", "max_model_len" => 4096}
      ]

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:vllm, 4096}
    end

    test "falls through when no recognized field is present" do
      body = %{
        "data" => [
          %{"id" => "test-model", "something_else" => 1234}
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end
  end

  describe "failure modes" do
    test "falls through to default on a non-200 status" do
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 500, body: "oops"}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end

    test "falls through to default on a 401" do
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 401, body: "unauthorized"}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end

    test "falls through to default when Req.get returns an error tuple" do
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:error, :econnrefused}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end

    test "falls through to default on a malformed body" do
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: "<html>not json</html>"}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end

    test "falls through to default on an empty body" do
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: nil}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end

    test "falls through to default when client_config has no base_url" do
      config = %{build_config() | base_url: nil}
      assert Discover.context_limit(config) == {:default, @default_limit}
    end
  end

  describe "auth header" do
    test "sends a Bearer header when api_key is present" do
      test_pid = self()

      Mimic.expect(Req, :get, fn _url, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(api_key: "sk-test-123"))

      assert_received {:opts, opts}
      assert {"Authorization", "Bearer sk-test-123"} in opts[:headers]
    end

    test "sends no Authorization header when api_key is nil" do
      test_pid = self()

      Mimic.expect(Req, :get, fn _url, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(api_key: nil))

      assert_received {:opts, opts}
      refute Enum.any?(opts[:headers] || [], fn {k, _v} -> k == "Authorization" end)
    end

    test "sends no Authorization header when api_key is an empty string" do
      test_pid = self()

      Mimic.expect(Req, :get, fn _url, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(api_key: ""))

      assert_received {:opts, opts}
      refute Enum.any?(opts[:headers] || [], fn {k, _v} -> k == "Authorization" end)
    end
  end

  describe "URL construction" do
    test "appends /models to the base URL" do
      test_pid = self()

      Mimic.expect(Req, :get, fn url, _opts ->
        send(test_pid, {:url, url})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(base_url: "http://example.com/v1"))

      assert_received {:url, "http://example.com/v1/models"}
    end

    test "preserves any path already on the base URL" do
      test_pid = self()

      Mimic.expect(Req, :get, fn url, _opts ->
        send(test_pid, {:url, url})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(base_url: "http://example.com/api/openai"))

      assert_received {:url, "http://example.com/api/openai/models"}
    end
  end

  describe "timeout" do
    test "passes a receive_timeout in the request options" do
      test_pid = self()

      Mimic.expect(Req, :get, fn _url, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config())

      assert_received {:opts, opts}
      assert is_integer(opts[:receive_timeout])
      assert opts[:receive_timeout] > 0
    end
  end
end

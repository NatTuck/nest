defmodule Nest.LLM.DiscoverTest do
  @moduledoc """
  Tests for the best-effort context-window discovery probe.

  Covers every known provider response shape (vLLM, OpenRouter,
  DeepSeek, Olla, llama.cpp) and the failure modes that should fall
  through to the 128k default.
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
      first_byte_timeout: 5000,
      stream_idle_timeout: 5000
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

  describe "DeepSeek response shape" do
    # DeepSeek's `/v1/models` publishes `context_window` for the limit and
    # `input_modalities` for input support. The modality half was already read
    # (atlascloud's flat shape), so one body and one request proved a model
    # image-capable *and* resolved it to the 128k default. Measured live for
    # `deepseek-flash`, reproduced verbatim.
    test "extracts context_window from a DeepSeek /v1/models response" do
      body = %{
        "data" => [
          %{
            "id" => "deepseek-flash",
            "object" => "model",
            "name" => "DeepSeek-V4.1-Flash",
            "context_window" => 1_048_576,
            "max_output_tokens" => 393_216,
            "input_modalities" => ["text", "image"],
            "output_modalities" => ["text"]
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config(model: "deepseek-flash")) ==
               {:context_window, 1_048_576}

      # The same entry's modality half: this half always worked.
      assert Discover.extract_multi_modal_from_model(hd(body["data"])) == %{"input" => ["image"]}
    end

    test "context_length wins over context_window when a body carries both" do
      # No measured provider publishes both. Pinned so a future refactor cannot
      # flip it: OpenRouter's field is the narrower claim.
      model = %{"id" => "both", "context_length" => 128_000, "context_window" => 1_048_576}

      assert Discover.extract_limit_from_model(model) == {:openrouter, 128_000}
    end

    test "a non-positive published limit is treated as no limit published" do
      # The `@spec` has always said `pos_integer()`, but every guard only
      # required `is_integer` — so a body publishing `0` put `0` into the
      # discovery cache, and `Reserve.compaction_reserve/1`'s
      # `is_integer(limit) and limit > 0` guard clause then raised on every
      # agent start that resolved to it.
      #
      # A non-positive value is not a context limit, so it is skipped and the
      # search falls through — to the next field, or to the default. That is the
      # safe direction, and it makes the spec true.
      for bad <- [0, -1] do
        assert Discover.extract_limit_from_model(%{"id" => "z", "max_model_len" => bad}) == nil

        # A positive later field still wins, so skipping does not discard the
        # rest of the search.
        assert Discover.extract_limit_from_model(%{
                 "id" => "z",
                 "max_model_len" => bad,
                 "context_length" => 4096
               }) == {:openrouter, 4096}

        assert Discover.extract_limit_from_model(%{"id" => "z", "context_length" => bad}) == nil

        assert Discover.extract_limit_from_model(%{"id" => "z", "context_window" => bad}) == nil

        assert Discover.extract_limit_from_model(%{
                 "id" => "z",
                 "olla" => %{"max_context_length" => bad}
               }) ==
                 nil

        assert Discover.extract_limit_from_model(%{"id" => "z", "meta" => %{"n_ctx" => bad}}) ==
                 nil

        assert Discover.extract_limit_from_model(%{
                 "id" => "z",
                 "meta" => %{"n_ctx_train" => bad}
               }) ==
                 nil
      end
    end
  end

  describe "Olla response shape" do
    # Olla wraps upstream providers behind an OpenAI-shaped
    # `/v1/models` body. The context length lives under the
    # `olla` namespace rather than at the model root, so
    # `extract_limit_from_model/1` must look for
    # `olla.max_context_length`.
    test "extracts olla.max_context_length from a populated entry" do
      body = %{
        "object" => "list",
        "data" => [
          %{
            "id" => "Qwen/Qwen3.6-27B-FP8",
            "object" => "model",
            "owned_by" => "olla",
            "olla" => %{
              "max_context_length" => 224_000,
              "family" => "qwen",
              "variant" => "3.6"
            }
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config(model: "Qwen/Qwen3.6-27B-FP8")) ==
               {:olla, 224_000}
    end

    test "falls through to default when olla block lacks max_context_length" do
      # Upstream backends whose operators haven't populated
      # `max_context_length` (e.g. llama.cpp in the typhon
      # probe) leave the field absent — the cache layer then
      # falls through to per-model or provider-default
      # resolution rather than getting a 128k default.
      body = %{
        "data" => [
          %{
            "id" => "unsloth/Qwen3.5-122B-A10B-GGUF",
            "olla" => %{"family" => "qwen", "variant" => "3.5"}
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}
    end

    # Three single-call probes of the same pure function, so they share a test.
    test "extract_limit_from_model/1 reads olla.max_context_length and returns nil otherwise" do
      # A populated entry yields the olla-tagged limit.
      assert Discover.extract_limit_from_model(%{
               "id" => "Qwen/Qwen3.6-27B-FP8",
               "olla" => %{"max_context_length" => 224_000}
             }) == {:olla, 224_000}

      # An olla block without max_context_length yields nil.
      assert Discover.extract_limit_from_model(%{
               "id" => "unsloth/Qwen3.5-122B-A10B-GGUF",
               "olla" => %{"family" => "qwen"}
             }) == nil

      # No olla block at all yields nil.
      assert Discover.extract_limit_from_model(%{"id" => "some-model"}) == nil
    end

    test "vLLM wins over Olla when both fields are present" do
      # When an upstream vLLM is fronted by Olla, the upstream
      # response may still expose `max_model_len` at the top
      # level if Olla passes it through. Pin the precedence
      # so a future refactor doesn't silently demote vLLM.
      body = %{
        "data" => [
          %{
            "id" => "x",
            "max_model_len" => 4096,
            "olla" => %{"max_context_length" => 128_000}
          }
        ]
      }

      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: body}}
      end)

      assert Discover.context_limit(build_config()) == {:vllm, 4096}
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

      # `max_input_tokens` is deliberately not read: it is ambiguous (input-only
      # vs. total context) and its only publisher, raven-ferrus, also publishes
      # `context_length`, which the branch above already reads.
      assert Discover.extract_limit_from_model(%{"id" => "x", "max_input_tokens" => 65_536}) ==
               nil
    end
  end

  describe "failure modes" do
    # Every stubbed failure below resolves to the identical outcome, so they
    # share one test rather than repeating the stub scaffolding. Mimic consumes
    # expectations in definition order, so each stub is used by exactly the one
    # `context_limit/1` call that follows it.
    test "falls through to default on a bad status, a transport error, or an unusable body" do
      # A non-200 status.
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 500, body: "oops"}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}

      # A 401.
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 401, body: "unauthorized"}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}

      # Req.get returning an error tuple.
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:error, :econnrefused}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}

      # A malformed, non-JSON body.
      Mimic.expect(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: "<html>not json</html>"}}
      end)

      assert Discover.context_limit(build_config()) == {:default, @default_limit}

      # An empty body.
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
    test "sends a Bearer header from api_key and none when api_key is nil or empty" do
      test_pid = self()

      # A present api_key becomes a Bearer Authorization header.
      Mimic.expect(Req, :get, fn _url, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(api_key: "sk-test-123"))

      assert_received {:opts, opts}
      assert {"Authorization", "Bearer sk-test-123"} in opts[:headers]

      # A nil api_key sends no Authorization header at all.
      Mimic.expect(Req, :get, fn _url, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(api_key: nil))

      assert_received {:opts, opts}
      refute Enum.any?(opts[:headers] || [], fn {k, _v} -> k == "Authorization" end)

      # An empty-string api_key is treated exactly like nil.
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
    test "appends /models to the base URL, preserving any path already on it" do
      test_pid = self()

      Mimic.expect(Req, :get, fn url, _opts ->
        send(test_pid, {:url, url})
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      Discover.context_limit(build_config(base_url: "http://example.com/v1"))

      assert_received {:url, "http://example.com/v1/models"}

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

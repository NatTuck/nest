# A Req adapter that always fails with a transient transport error and counts
# its invocations. Req runs the adapter in the caller's process on this
# synchronous path, so a process-dictionary counter is enough. Driving Req's
# *real* retry step is the point: stubbing `Req.post/2` instead would bypass the
# step that does the retrying, and the repo forbids real HTTP in tests.
#
# It *returns* the exception (`{request, exception}`), mirroring Req's own Finch
# adapter (`deps/req/lib/req/finch.ex:305`) — that returned value is what puts
# the retry step (an error step) in play. Raising instead would bypass the
# error-step pipeline and escape `Req.post/2`, proving nothing.
defmodule Nest.LLM.HttpWorkerTest.StubAdapter do
  @moduledoc false

  def run(request) do
    Process.put(:attempts, (Process.get(:attempts) || 0) + 1)
    {request, %Req.TransportError{reason: :closed}}
  end
end

defmodule Nest.LLM.HttpWorkerTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.HttpWorker

  # Stand-in for a client's `format_chunk/3`: the real ones JSON-encode the
  # chunk, but the failure *body* is what these tests are about.
  defp chunk(kind, status, body), do: "#{kind}|#{status}|#{body}"

  defp ctx do
    %{
      host: "api.example.com",
      model: "deepseek-v4-flash",
      messages: 412,
      retries: 2,
      started_at: System.monotonic_time(:millisecond) - 18
    }
  end

  describe "retry_opts/1" do
    test "retries transient transport failures for POST" do
      opts = HttpWorker.retry_opts([])

      # `:transient`, not Req's `:safe_transient` default: a chat completion is
      # a POST, and the default only retries safe/idempotent methods.
      assert opts[:retry] == :transient
      assert opts[:max_retries] == 2
    end

    test "lets a caller override part of the policy" do
      opts = HttpWorker.retry_opts(retry_opts: [max_retries: 0, retry_delay: fn _ -> 0 end])

      assert opts[:max_retries] == 0
      assert opts[:retry] == :transient
      assert is_function(opts[:retry_delay], 1)
    end
  end

  describe "context/4" do
    test "names the endpoint, model, request size and retry budget" do
      ctx = HttpWorker.context("https://api.example.com/v1/chat/completions", "m", [1, 2, 3], [])

      assert ctx.host == "api.example.com"
      assert ctx.model == "m"
      assert ctx.messages == 3
      assert ctx.retries == 2
      assert is_integer(ctx.started_at)
    end

    test "survives a missing url or message list" do
      ctx = HttpWorker.context(nil, nil, nil, [])

      assert ctx.host == nil
      assert ctx.messages == 0
    end
  end

  describe "handle_response/5 failure descriptions" do
    test "a closed connection names the cause, endpoint and attempt budget" do
      assert :ok =
               HttpWorker.handle_response(
                 {:error, %Req.TransportError{reason: :closed}},
                 self(),
                 "OpenAIClient",
                 &chunk/3,
                 ctx()
               )

      assert_receive {:req_chunk, body}

      assert body =~ "the provider closed the connection before responding"
      assert body =~ "host=api.example.com"
      assert body =~ "model=deepseek-v4-flash"
      assert body =~ "messages=412"
      assert body =~ "retries=2"
      assert body =~ ~r/elapsed=\d+ms/
      # The raw reason stays on its own line: it is what we grep for.
      assert body =~ "%Req.TransportError{reason: :closed}"

      assert_receive :req_done
    end

    test "a refused connection says so rather than printing a reason atom" do
      assert :ok =
               HttpWorker.handle_response(
                 {:error, %Req.TransportError{reason: :econnrefused}},
                 self(),
                 "AnthropicClient",
                 &chunk/3,
                 ctx()
               )

      assert_receive {:req_chunk, body}
      assert body =~ "could not connect to the provider"
      assert body =~ "host=api.example.com"
    end

    test "a non-200 carries the provider's body and the context" do
      assert :ok =
               HttpWorker.handle_response(
                 {:ok, %Req.Response{status: 429, body: "rate limited"}},
                 self(),
                 "OpenAIClient",
                 &chunk/3,
                 ctx()
               )

      assert_receive {:req_chunk, body}
      assert body =~ "the provider returned HTTP 429"
      assert body =~ "rate limited"
      assert body =~ "host=api.example.com"

      assert_receive :req_done
    end

    test "a decoded (non-binary) error body is rendered as text, not a term" do
      assert :ok =
               HttpWorker.handle_response(
                 {:ok, %Req.Response{status: 400, body: %{"error" => %{"message" => "bad"}}}},
                 self(),
                 "OpenAIClient",
                 &chunk/3,
                 ctx()
               )

      assert_receive {:req_chunk, body}
      assert is_binary(body)
      assert body =~ "the provider returned HTTP 400"
    end

    test "renders without context when none was supplied" do
      assert :ok =
               HttpWorker.handle_response(
                 {:error, %Req.TransportError{reason: :closed}},
                 self(),
                 "OpenAIClient",
                 &chunk/3
               )

      assert_receive {:req_chunk, body}
      assert body =~ "the provider closed the connection before responding"
      refute body =~ "host="
      refute body =~ "elapsed="
    end
  end

  describe "retry_opts/1 as Req actually applies it" do
    # The policy is only worth anything if Req's retry step honours it for a
    # POST. These run the real step with a stub adapter, so the count is the
    # number of attempts Req made.
    defp post_through_stub(extra_opts) do
      Process.delete(:attempts)

      HttpWorker.retry_opts([])
      |> Keyword.merge(retry_delay: fn _ -> 0 end, retry_log_level: :debug)
      |> Keyword.merge(extra_opts)
      |> then(
        &Req.post(
          "http://127.0.0.1:1/v1/chat/completions",
          [json: %{"model" => "m"}, adapter: Nest.LLM.HttpWorkerTest.StubAdapter] ++ &1
        )
      )
    end

    test "a POST transport failure is retried twice (3 attempts)" do
      assert {:error, %Req.TransportError{reason: :closed}} = post_through_stub([])

      assert Process.get(:attempts) == 3
    end

    test "a caller can disable the retries" do
      assert {:error, %Req.TransportError{reason: :closed}} =
               post_through_stub(max_retries: 0)

      assert Process.get(:attempts) == 1
    end
  end
end

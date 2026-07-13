#!/usr/bin/env elixir
# Replicate the working curl call via Nest.LLM.OpenAIClient against
# http://typhon:8000/v1 (vLLM, model Qwen/Qwen3.5-35B-A3B).
# Always runs two passes: the Nest streaming request (what the app
# actually sends), and a non-streaming bisect over the same wire
# payload. Output is JSONL so the two passes are diff-comparable.
# Usage: mix run scripts/test-typhon-toolcall.exs

alias Nest.LLM.Client
alias Nest.LLM.OpenAIClient
alias Nest.LLM.RunRequest
alias Nest.LLM.RunResponse
alias Nest.LLM.Tool, as: LLMTool
alias Nest.Messages.Part
alias Nest.Messages.System
alias Nest.Messages.ToolCall
alias Nest.Messages.User

defmodule TyphonToolCallScript do
  @base_url "http://typhon:8000/v1"
  @model "Qwen/Qwen3.5-35B-A3B"
  @api_key "none"
  @receive_timeout 60_000

  def run do
    start = DateTime.utc_now()
    jsonl("session_start", %{base_url: @base_url, model: @model})

    request = build_request()

    streaming_start = DateTime.utc_now()
    jsonl("pass_start", %{pass: "streaming"})

    streaming_payload = OpenAIClient.format_request_payload(request, [])
    jsonl("wire_payload", %{pass: "streaming", payload: streaming_payload})

    {streaming_response, streaming_errored, streaming_event_count} =
      run_streaming_pass(request)

    jsonl("llm_response", %{
      pass: "streaming",
      text: streaming_response.text,
      tool_calls: Enum.map(streaming_response.tool_calls, &tool_call_to_log/1),
      finish_reason: streaming_response.stop_reason,
      usage: streaming_response.usage
    })

    jsonl("pass_summary", %{
      pass: "streaming",
      duration_ms: DateTime.diff(DateTime.utc_now(), streaming_start, :millisecond),
      event_count: streaming_event_count,
      errored: streaming_errored,
      tool_call_count: length(streaming_response.tool_calls)
    })

    non_streaming_start = DateTime.utc_now()
    jsonl("pass_start", %{pass: "non_streaming"})

    {non_streaming_response, non_streaming_errored} =
      run_non_streaming_pass(streaming_payload)

    jsonl("pass_summary", %{
      pass: "non_streaming",
      duration_ms: DateTime.diff(DateTime.utc_now(), non_streaming_start, :millisecond),
      errored: non_streaming_errored,
      text: non_streaming_response.text,
      tool_calls: Enum.map(non_streaming_response.tool_calls, &tool_call_to_log/1),
      finish_reason: non_streaming_response.stop_reason,
      usage: non_streaming_response.usage
    })

    jsonl("session_end", %{
      reason: "completed",
      total_duration_ms: DateTime.diff(DateTime.utc_now(), start, :millisecond)
    })
  end

  defp build_request do
    %RunRequest{
      model: @model,
      messages: [
        {:system,
         %System{
           index: 0,
           parts: [%Part.Text{text: "You are a helpful assistant."}]
         }},
        {:user,
         %User{
           index: 1,
           parts: [%Part.Text{text: "What is the weather in San Francisco?"}]
         }}
      ],
      tools: [build_get_weather_tool()],
      tool_choice: :auto,
      max_tokens: 256
    }
  end

  defp build_get_weather_tool do
    %LLMTool{
      name: "get_weather",
      description: "Get weather for a location",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"}
        },
        "required" => ["location"]
      },
      function: fn _args, _ctx -> {:ok, "Sunny, 72F"} end
    }
  end

  # Drive the streaming pass through OpenAIClient.run/2 (so the
  # canonical event stream reflects exactly what the agent sees)
  # and ALSO replay the same wire payload via a raw Req.post so we
  # capture the actual transport-layer response (status, headers,
  # raw SSE bytes) — the OpenAIClient.http_worker discards the
  # reason for transport-level failures, which is the most common
  # thing to investigate on a flaky local server.
  defp run_streaming_pass(request) do
    raw_payload = OpenAIClient.format_request_payload(request, [])
    jsonl("pass_sub_start", %{pass: "streaming", sub: "raw_replay"})

    {raw_status, raw_body, raw_chunks, raw_error} =
      replay_raw_streaming(raw_payload)

    jsonl("raw_status", %{pass: "streaming", status: raw_status, error: raw_error})
    jsonl("raw_chunks", %{pass: "streaming", chunks: raw_chunks})
    if raw_body != nil, do: jsonl("raw_body_combined", %{pass: "streaming", body: raw_body})

    jsonl("pass_sub_start", %{pass: "streaming", sub: "canonical"})
    {response, errored, event_count} = run_canonical_streaming(request)
    {response, errored, event_count}
  end

  defp replay_raw_streaming(payload) do
    url = OpenAIClient.normalize_endpoint(@base_url, "/chat/completions")

    result =
      Req.post(url,
        auth: {:bearer, @api_key},
        json: payload,
        receive_timeout: @receive_timeout,
        into: :self,
        http_errors: :return,
        max_retries: 0
      )

    case result do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{} = async_body}} ->
        chunks = Enum.to_list(async_body)

        jsonl("raw_chunk", %{pass: "streaming", sub: "raw_replay", index: 0, bytes: "streaming started"})

        combined = Enum.reduce(Enum.with_index(chunks), "", fn {chunk, i}, acc ->
          jsonl("raw_chunk", %{
            pass: "streaming",
            sub: "raw_replay",
            index: i,
            bytes: byte_size(chunk),
            chunk: chunk
          })
          acc <> chunk
        end)

        {200, combined, length(chunks), nil}

      {:ok, %Req.Response{status: status, body: body}} ->
        {status, body_to_binary(body), 0, nil}

      {:error, reason} ->
        {nil, nil, 0, inspect(reason)}
    end
  end

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(nil), do: nil
  defp body_to_binary(body), do: inspect(body)

  defp run_canonical_streaming(request) do
    {:ok, stream} = OpenAIClient.run(request, base_url: @base_url, api_key: @api_key, receive_timeout: @receive_timeout)

    {acc, events, errored} =
      Enum.reduce(stream, {Client.new_accumulator(), [], false}, fn event, {acc, evs, err} ->
        jsonl("event", %{pass: "streaming", sub: "canonical", index: length(evs), event: event_to_log(event)})

        new_errored = err or match?({:error, _}, event)
        {Client.accumulate(acc, event), evs ++ [event], new_errored}
      end)

    {Client.finalize(acc, @model), errored, length(events)}
  end

  defp run_non_streaming_pass(streaming_payload) do
    payload =
      streaming_payload
      |> Map.put("stream", false)
      |> Map.delete("stream_options")

    jsonl("wire_payload", %{pass: "non_streaming", payload: payload})

    url = OpenAIClient.normalize_endpoint(@base_url, "/chat/completions")

    case Req.post(url,
           auth: {:bearer, @api_key},
           json: payload,
           receive_timeout: @receive_timeout,
           max_retries: 0,
           http_errors: :return
         ) do
      {:ok, %{status: 200, body: body}} ->
        jsonl("raw_body", %{pass: "non_streaming", body: body})
        {response, _events} = synthesize_response_from_body(body)
        jsonl("llm_response", %{
          pass: "non_streaming",
          text: response.text,
          tool_calls: Enum.map(response.tool_calls, &tool_call_to_log/1),
          finish_reason: response.stop_reason,
          usage: response.usage
        })

        {response, false}

      {:ok, %{status: status, body: body}} ->
        jsonl("error", %{pass: "non_streaming", kind: "http_error", status: status, body: body})
        {%RunResponse{}, true}

      {:error, reason} ->
        jsonl("error", %{pass: "non_streaming", kind: "request_failed", reason: inspect(reason)})
        {%RunResponse{}, true}
    end
  end

  defp synthesize_response_from_body(body) when is_map(body) do
    choice = body |> get_in(["choices"]) |> List.first() || %{}
    message = choice["message"] || %{}
    finish_reason = choice["finish_reason"]
    usage = body["usage"] || %{}

    tool_calls =
      (message["tool_calls"] || [])
      |> Enum.map(fn tc ->
        %ToolCall{
          id: tc["id"],
          name: get_in(tc, ["function", "name"]),
          arguments: decode_args(get_in(tc, ["function", "arguments"]))
        }
      end)

    response = %RunResponse{
      text: message["content"],
      tool_calls: tool_calls,
      stop_reason: finish_reason,
      usage: parse_usage(usage),
      model: @model
    }

    {response, []}
  end

  defp synthesize_response_from_body(other) do
    jsonl("error", %{pass: "non_streaming", kind: "unexpected_body_shape", value: inspect(other)})
    {%RunResponse{}, []}
  end

  defp parse_usage(usage) do
    total_input = Map.get(usage, "prompt_tokens", 0)
    output = Map.get(usage, "completion_tokens", 0)
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    input = max(total_input - cached, 0)

    %{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cached,
      cache_creation_input_tokens: 0,
      reasoning_tokens: get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0,
      total_tokens: Map.get(usage, "total_tokens", input + output)
    }
  end

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_args(%{} = args), do: args
  defp decode_args(_), do: %{}

  defp event_to_log({:text, text}), do: %{kind: "text", text: text}
  defp event_to_log({:thinking, text}), do: %{kind: "thinking", text: text}
  defp event_to_log({:thinking_signature, signature}), do: %{kind: "thinking_signature", signature: signature}
  defp event_to_log({:refusal, refusal}), do: %{kind: "refusal", refusal: refusal}
  defp event_to_log({:tool_call_start, %{id: id, name: name} = m}),
    do: %{kind: "tool_call_start", id: id, name: name, index: m[:index]}
  defp event_to_log({:tool_call_delta, %{id: id, index: idx, arguments_delta: delta}}),
    do: %{kind: "tool_call_delta", id: id, index: idx, arguments_delta: delta}
  defp event_to_log({:usage, usage}), do: %{kind: "usage", usage: usage}
  defp event_to_log({:finish_reason, reason}), do: %{kind: "finish_reason", reason: reason}
  defp event_to_log({:done, _}), do: %{kind: "done"}
  defp event_to_log({:error, error}), do: %{kind: "error", error: error}
  defp event_to_log(other), do: %{kind: "other", value: inspect(other)}

  defp tool_call_to_log(%ToolCall{id: id, name: name, arguments: args}) do
    %{id: id, name: name, arguments: args}
  end

  defp jsonl(type, fields) do
    line =
      fields
      |> Map.put(:type, type)
      |> Map.put(:timestamp, DateTime.to_iso8601(DateTime.utc_now()))

    IO.puts(Jason.encode!(line))
  end
end

TyphonToolCallScript.run()

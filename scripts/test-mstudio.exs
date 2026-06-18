#!/usr/bin/env elixir
# Test script for model-studio provider with qwen3-plus
# Usage: mix run scripts/test-mstudio.exs

alias Nest.ChatModel
alias Nest.DotConfig
alias Nest.LLM.Client
alias Nest.LLM.RunRequest
alias Nest.Messages.User

IO.puts("Loading configuration...")

config = DotConfig.load!()

provider =
  case DotConfig.get_provider(config, "model-studio") do
    nil ->
      IO.puts("Error: model-studio provider not found in config")
      System.halt(1)

    p ->
      p
  end

IO.puts("Provider found: #{provider.name}")
IO.puts("Base URL: #{provider.base_url}")
IO.puts("")

# Resolve to a Nest.LLM.ClientConfig
client_config =
  case ChatModel.from_provider("model-studio", "MiniMax-M2.5") do
    {:ok, cfg} ->
      cfg

    {:error, reason} ->
      IO.puts("Error creating client config: #{inspect(reason)}")
      System.halt(1)
  end

IO.puts("Using model: #{client_config.model}")
IO.puts("")

start_time = DateTime.utc_now()

session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

logs = [
  %{
    type: "session_start",
    timestamp: DateTime.to_iso8601(start_time),
    id: session_id,
    provider: provider.name,
    model: client_config.model
  },
  %{
    type: "config",
    timestamp: DateTime.to_iso8601(DateTime.utc_now()),
    provider: provider.name,
    base_url: provider.base_url,
    model: client_config.model
  },
  %{
    type: "user_message",
    timestamp: DateTime.to_iso8601(DateTime.utc_now()),
    index: 0,
    content: "Hi",
    metadata: %{}
  }
]

# Build the canonical request and run the client
request = %RunRequest{
  model: client_config.model,
  messages: [{:user, %User{index: 0, content: "Hi"}}]
}

opts = [
  base_url: client_config.base_url,
  api_key: client_config.api_key,
  receive_timeout: client_config.receive_timeout
]

IO.puts("Sending message: 'Hi'")
IO.puts("")

# Run the client and fold the stream into a RunResponse
run_response =
  {:ok, stream} = client_config.client.run(request, opts)

  {acc, response, _error, _sent} =
    Enum.reduce(
      stream,
      {Client.new_accumulator(), nil, nil, %{}},
      fn
        event, {acc, nil, error, sent} ->
          {Client.accumulate(acc, event), nil, error, sent}

        _, {acc, resp, error, sent} ->
          {acc, resp, error, sent}
      end
    )

  response || Client.finalize(acc, client_config.model)

end_time = DateTime.utc_now()

duration_ms = DateTime.diff(end_time, start_time, :millisecond)

logs =
  logs ++
    [
      %{
        type: "llm_response",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        full_content: run_response.text || "",
        finish_reason: run_response.stop_reason,
        duration_ms: duration_ms
      },
      %{
        type: "assistant_message",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        index: 1,
        content: run_response.text || "",
        metadata: %{}
      },
      %{
        type: "session_end",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        reason: "completed",
        total_duration_ms: duration_ms
      }
    ]

IO.puts("=== JSONL Output ===")
IO.puts("")

Enum.each(logs, fn log_entry -> IO.puts(Jason.encode!(log_entry)) end)

IO.puts("")
IO.puts("=== Response Content ===")
IO.puts(run_response.text || "")

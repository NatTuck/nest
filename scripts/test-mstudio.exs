#!/usr/bin/env elixir
# Test script for model-studio provider with qwen3-plus
# Usage: mix run scripts/test-mstudio.exs

alias Nest.DotConfig
alias Nest.ChatModel
alias LangChain.Chains.LLMChain
alias LangChain.Message

IO.puts("Loading configuration...")

# Load config
config = DotConfig.load!()

# Get model-studio provider
provider = DotConfig.get_provider(config, "model-studio")

unless provider do
  IO.puts("Error: model-studio provider not found in config")
  System.halt(1)
end

IO.puts("Provider found: #{provider.name}")
IO.puts("Base URL: #{provider.base_url}")
IO.puts("")

# Create chat model with specific model
IO.puts("Creating LLM chain for qwen3-plus...")

llm_chain =
  try do
    ChatModel.new(provider: "model-studio", model: "MiniMax-M2.5")
  rescue
    e ->
      IO.puts("Error creating chat model: #{e.message}")
      System.halt(1)
  end

IO.puts("Using model: #{llm_chain.llm.model}")
IO.puts("")

# Send "Hi" and capture response
IO.puts("Sending message: 'Hi'")
IO.puts("")

# Add user message
llm_chain = LLMChain.add_message(llm_chain, Message.new_user!("Hi"))

# Build initial log entries
start_time = DateTime.utc_now()
logs = []

# Session start log
session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
logs =
  logs ++
    [
      %{
        type: "session_start",
        timestamp: DateTime.to_iso8601(start_time),
        id: session_id,
        provider: provider.name,
        model: llm_chain.llm.model
      }
    ]

# Config log
logs =
  logs ++
    [
      %{
        type: "config",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        provider: provider.name,
        base_url: provider.base_url,
        model: llm_chain.llm.model
      }
    ]

# User message log
logs =
  logs ++
    [
      %{
        type: "user_message",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        index: 0,
        content: "Hi",
        metadata: %{}
      }
    ]

# LLM request log
logs =
  logs ++
    [
      %{
        type: "llm_request",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        message_count: length(llm_chain.messages)
      }
    ]

# Run the chain
IO.puts("Running inference...")
IO.puts("")

result =
  try do
    LLMChain.run(llm_chain)
  rescue
    e ->
      IO.puts("Error during inference: #{inspect(e)}")
      System.halt(1)
  end

end_time = DateTime.utc_now()

# Handle result
case result do
  {:ok, final_chain} ->
    last_message = List.last(final_chain.messages)

    # LLM response log
    logs =
      logs ++
        [
          %{
            type: "llm_response",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            full_content: last_message.content,
            finish_reason: last_message.status,
            duration_ms: DateTime.diff(end_time, start_time, :millisecond)
          }
        ]

    # Assistant message log
    logs =
      logs ++
        [
          %{
            type: "assistant_message",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            index: 1,
            content: last_message.content,
            metadata: %{}
          }
        ]

    # Session end log
    logs =
      logs ++
        [
          %{
            type: "session_end",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            reason: "completed",
            total_duration_ms: DateTime.diff(end_time, start_time, :millisecond)
          }
        ]

    # Output as JSONL
    IO.puts("=== JSONL Output ===")
    IO.puts("")

    logs
    |> Enum.each(fn log_entry ->
      IO.puts(Jason.encode!(log_entry))
    end)

    IO.puts("")
    IO.puts("=== Response Content ===")
    
    content = last_message.content
    text_content = 
      if is_list(content) do
        content
        |> Enum.filter(&(&1.type == :text))
        |> Enum.map(&(&1.content))
        |> Enum.join("")
      else
        content
      end
    
    IO.puts(text_content)

  {:error, _chain, error} ->
    IO.puts("Error: #{error.message}")
    IO.puts("Error type: #{error.type}")
    if error.original do
      IO.puts("Original: #{inspect(error.original)}")
    end

    # Error log
    error_logs =
      logs ++
        [
          %{
            type: "session_end",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            reason: "error",
            error: error.message
          }
        ]

    error_logs
    |> Enum.each(fn log_entry ->
      IO.puts(Jason.encode!(log_entry))
    end)

    System.halt(1)
end

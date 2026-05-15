#!/usr/bin/env elixir
# Test script for pegasus provider with dice rolling tool
# Usage: mix run scripts/test-pegasus.exs

alias Nest.DotConfig
alias Nest.ChatModel
alias LangChain.Chains.LLMChain
alias LangChain.Message
alias LangChain.Function

IO.puts("Loading configuration...")

# Load config
config = DotConfig.load!()

# Get pegasus provider
provider = DotConfig.get_provider(config, "pegasus")

unless provider do
  IO.puts("Error: pegasus provider not found in config")
  System.halt(1)
end

IO.puts("Provider found: #{provider.name}")
IO.puts("Base URL: #{provider.base_url}")
IO.puts("Auto-models: #{provider.auto_models}")
IO.puts("")

# Agent state for logging
defmodule AgentState do
  def start_link, do: Agent.start_link(fn -> [] end)
  def get_logs(pid), do: Agent.get(pid, & &1)
  def add_log(pid, log), do: Agent.update(pid, & &1 ++ [log])
end

{:ok, logs_agent} = AgentState.start_link()

# Create dice rolling tool
dice_tool =
  Function.new!(%{
    name: "roll",
    description: "Roll dice in standard dice notation (e.g., '3d6' rolls 3 six-sided dice, '2d10' rolls 2 ten-sided dice). Returns the total sum and individual rolls.",
    parameters_schema: %{
      type: "object",
      properties: %{
        notation: %{
          type: "string",
          description: "Dice notation like '3d6', '2d10', '1d20', etc. Format: {number}d{sides}"
        }
      },
      required: ["notation"]
    },
    function: fn %{"notation" => notation} = args, context ->
      # Log the tool call
      call_id = context.tool_call_id
      
      AgentState.add_log(context.logs_agent, %{
        type: "tool_call",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        tool: "roll",
        arguments: args,
        call_id: call_id
      })

      # Parse dice notation like "3d6"
      result =
        case Regex.run(~r/(\d+)d(\d+)/i, notation) do
          [_, count_str, sides_str] ->
            count = String.to_integer(count_str)
            sides = String.to_integer(sides_str)

            # Roll the dice
            rolls = for _ <- 1..count, do: :rand.uniform(sides)
            total = Enum.sum(rolls)

            result = %{
              notation: notation,
              rolls: rolls,
              total: total,
              count: count,
              sides: sides
            }

            {:ok, Jason.encode!(result)}

          nil ->
            {:error, "Invalid dice notation: #{notation}. Use format like '3d6' or '2d10'"}
        end

      # Log the tool result
      {status, content} = result

      AgentState.add_log(context.logs_agent, %{
        type: "tool_result",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        tool: "roll",
        call_id: call_id,
        result: content,
        status: status
      })

      result
    end
  })

# Create chat model
IO.puts("Creating LLM chain...")

llm_chain =
  try do
    ChatModel.new(provider: "pegasus")
  rescue
    e ->
      IO.puts("Error creating chat model: #{e.message}")
      System.halt(1)
  end

# Add the dice tool to the chain
llm_chain = LLMChain.add_tools(llm_chain, [dice_tool])

IO.puts("Using model: #{llm_chain.llm.model}")
IO.puts("Tools: roll")
IO.puts("")

# Send message asking to roll D&D attributes
IO.puts("Sending message: 'Roll up D&D attributes (STR, DEX, CON, INT, WIS, CHA) using 3d6 for each'")
IO.puts("")

# Add user message
llm_chain = LLMChain.add_message(llm_chain, Message.new_user!("Roll up D&D attributes (STR, DEX, CON, INT, WIS, CHA) using 3d6 for each. Show me the rolls and the final scores."))

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
        model: llm_chain.llm.model,
        tools: ["roll"]
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
        content: "Roll up D&D attributes using 3d6 for each",
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
        message_count: length(llm_chain.messages),
        tools: ["roll"]
      }
    ]

# Add custom context for logging
llm_chain = %{
  llm_chain
  | custom_context: %{
      logs_agent: logs_agent
    }
}

# Run the chain
IO.puts("Running inference (may take multiple turns for tool calls)...")
IO.puts("")

result =
  try do
    # Use :while_needs_response to handle tool calls automatically
    LLMChain.run(llm_chain, mode: :while_needs_response)
  rescue
    e ->
      IO.puts("Error during inference: #{inspect(e)}")
      System.halt(1)
  end

end_time = DateTime.utc_now()

# Get tool logs from agent
tool_logs = AgentState.get_logs(logs_agent)

# Handle result
case result do
  {:ok, final_chain} ->
    last_message = List.last(final_chain.messages)

    # Add tool logs to our logs
    logs = logs ++ tool_logs

    # LLM response log
    logs =
      logs ++
        [
          %{
            type: "llm_response",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            full_content: last_message.content,
            finish_reason: last_message.status,
            duration_ms: DateTime.diff(end_time, start_time, :millisecond),
            tool_calls_count: length(tool_logs) / 2
          }
        ]

    # Assistant message log
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

    logs =
      logs ++
        [
          %{
            type: "assistant_message",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            index: 1,
            content: text_content,
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
            total_duration_ms: DateTime.diff(end_time, start_time, :millisecond),
            tool_calls: length(tool_logs) / 2
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
    IO.puts(text_content)

    # Show tool calls summary
    tool_calls_summary =
      tool_logs
      |> Enum.filter(&(&1.type == "tool_call"))
      |> Enum.map(& &1.arguments)

    if tool_calls_summary != [] do
      IO.puts("")
      IO.puts("=== Tool Calls Summary ===")

      tool_calls_summary
      |> Enum.each(fn args ->
        IO.puts("roll(#{Jason.encode!(args)})")
      end)
    end

  {:error, _chain, error} ->
    IO.puts("Error: #{error.message}")
    IO.puts("Error type: #{error.type}")

    if error.original do
      IO.puts("Original: #{inspect(error.original)}")
    end

    # Get any tool logs that were generated before error
    logs = logs ++ AgentState.get_logs(logs_agent)

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

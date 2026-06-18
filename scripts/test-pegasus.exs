#!/usr/bin/env elixir
# Test script for pegasus provider with dice rolling tool
# Usage: mix run scripts/test-pegasus.exs

alias Nest.ChatModel
alias Nest.DotConfig
alias Nest.LLM.Client
alias Nest.LLM.RunRequest
alias Nest.LLM.Tool, as: LLMTool
alias Nest.LLM.Tools
alias Nest.Messages.Tool
alias Nest.Messages.ToolCall
alias Nest.Messages.User

defmodule PegasusScript do
  @max_iterations 5

  def run do
    IO.puts("Loading configuration...")

    config = DotConfig.load!()

    provider =
      case DotConfig.get_provider(config, "pegasus") do
        nil ->
          IO.puts("Error: pegasus provider not found in config")
          System.halt(1)

        p ->
          p
      end

    IO.puts("Provider found: #{provider.name}")
    IO.puts("Base URL: #{provider.base_url}")
    IO.puts("Auto-models: #{provider.auto_models}")
    IO.puts("")

    {:ok, _} = ToolLogs.start_link()

    dice_tool = build_dice_tool()

    client_config =
      case ChatModel.from_provider("pegasus", nil) do
        {:ok, cfg} ->
          cfg

        {:error, reason} ->
          IO.puts("Error creating client config: #{inspect(reason)}")
          System.halt(1)
      end

    IO.puts("Using model: #{client_config.model}")
    IO.puts("Tools: roll")
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
        model: client_config.model,
        tools: ["roll"]
      }
    ]

    request = %RunRequest{
      model: client_config.model,
      tools: [dice_tool],
      tool_choice: :auto,
      messages: [
        {:user,
         %User{
           index: 0,
           content:
             "Roll up D&D attributes (STR, DEX, CON, INT, WIS, CHA) using 3d6 for each. Show me the rolls and the final scores."
         }}
      ]
    }

    opts = [
      base_url: client_config.base_url,
      api_key: client_config.api_key,
      receive_timeout: client_config.receive_timeout
    ]

    IO.puts("Running inference (may take multiple turns for tool calls)...")
    IO.puts("")

    run_response = run_with_tool_loop(request, client_config, opts, [dice_tool], @max_iterations)

    end_time = DateTime.utc_now()
    duration_ms = DateTime.diff(end_time, start_time, :millisecond)

    tool_logs = ToolLogs.all()

    final_logs =
      logs ++
        tool_logs ++
        [
          %{
            type: "llm_response",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            full_content: run_response.text || "",
            finish_reason: run_response.stop_reason,
            duration_ms: duration_ms,
            tool_calls_count: Enum.count(tool_logs, &(&1.type == "tool_call"))
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
            total_duration_ms: duration_ms,
            tool_calls: Enum.count(tool_logs, &(&1.type == "tool_call"))
          }
        ]

    IO.puts("=== JSONL Output ===")
    IO.puts("")

    Enum.each(final_logs, fn log_entry -> IO.puts(Jason.encode!(log_entry)) end)

    IO.puts("")
    IO.puts("=== Response Content ===")
    IO.puts(run_response.text || "")

    tool_calls_summary =
      tool_logs
      |> Enum.filter(&(&1.type == "tool_call"))
      |> Enum.map(& &1.arguments)

    if tool_calls_summary != [] do
      IO.puts("")
      IO.puts("=== Tool Calls Summary ===")

      Enum.each(tool_calls_summary, fn args ->
        IO.puts("roll(#{Jason.encode!(args)})")
      end)
    end
  end

  defp build_dice_tool do
    %LLMTool{
      name: "roll",
      description:
        "Roll dice in standard dice notation (e.g., '3d6' rolls 3 six-sided dice, " <>
          "'2d10' rolls 2 ten-sided dice). Returns the total sum and individual rolls.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "notation" => %{
            "type" => "string",
            "description" => "Dice notation like '3d6', '2d10', '1d20', etc."
          }
        },
        "required" => ["notation"]
      },
      function: fn args, context ->
        notation = Map.get(args, "notation", "")
        call_id = context[:tool_call_id]

        ToolLogs.add(%{
          type: "tool_call",
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          tool: "roll",
          arguments: args,
          call_id: call_id
        })

        result =
          case Regex.run(~r/(\d+)d(\d+)/i, notation) do
            [_, count_str, sides_str] ->
              count = String.to_integer(count_str)
              sides = String.to_integer(sides_str)
              rolls = for _ <- 1..count, do: :rand.uniform(sides)
              total = Enum.sum(rolls)

              {:ok,
               Jason.encode!(%{
                 notation: notation,
                 rolls: rolls,
                 total: total,
                 count: count,
                 sides: sides
               })}

            nil ->
              {:error, "Invalid dice notation: #{notation}. Use format like '3d6' or '2d10'"}
          end

        {status, content} = result

        ToolLogs.add(%{
          type: "tool_result",
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          tool: "roll",
          call_id: call_id,
          result: content,
          status: status
        })

        result
      end
    }
  end

  defp run_with_tool_loop(request, client_config, opts, tools, budget) do
    do_run_with_tool_loop(request, client_config, opts, tools, budget)
  end

  defp do_run_with_tool_loop(_request, _client_config, _opts, _tools, 0) do
    IO.puts("Tool call iteration budget exceeded; stopping.")
    %Client.RunResponse{}
  end

  defp do_run_with_tool_loop(request, client_config, opts, tools, budget) do
    {:ok, stream} = client_config.client.run(request, opts)

    {acc, _final, _error, _sent} =
      Enum.reduce(
        stream,
        {Client.new_accumulator(), nil, nil, %{}},
        fn event, {acc, _, _, _} ->
          {Client.accumulate(acc, event), nil, nil, %{}}
        end
      )

    response = Client.finalize(acc, client_config.model)

    if response.tool_calls == [] do
      response
    else
      # Execute the tool calls, append them as a :tool message,
      # and re-run with an updated request. The assistant's
      # text (if any) is appended as a User message because
      # this script doesn't persist assistant turns through
      # the proper schema.
      results = Tools.execute(tools, response.tool_calls, %{tool_call_id: nil})

      next_index = length(request.messages)

      tool_message =
        {:tool, %Tool{index: next_index, tool_results: results}}

      user_message =
        {:user, %User{index: next_index, content: response.text || ""}}

      next_request = %RunRequest{
        request
        | messages: request.messages ++ [user_message, tool_message]
      }

      do_run_with_tool_loop(next_request, client_config, opts, tools, budget - 1)
    end
  end
end

defmodule ToolLogs do
  use Agent

  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def add(entry), do: Agent.update(__MODULE__, &(&1 ++ [entry]))
  def all, do: Agent.get(__MODULE__, & &1)
end

PegasusScript.run()

# scripts/minimax-chat-probe.exs
#
# Probes `MiniMax-M3` via the chat completion endpoint with the
# EXACT payload shape that Nest's `OpenAIClient.format_request_payload/2`
# produces. Runs three variants to localize the cause of the
# "model emits a think then stops, no follow-up" behavior seen
# in production.
#
# Run with:
#   mix run scripts/minimax-chat-probe.exs
#
# Reads:
#   * ~/.config/nest/config.toml  (the [providers.minimax] block)
#   * AGENTS.md at the project root
# Writes: stdout only. No files are created. No project files
# are modified.

defmodule MiniMaxChatProbe do
  @model "MiniMax-M3"
  @max_iterations 50
  @context_limit 200_000
  @workspace "/home/nat/Code/nest"
  @max_result_tokens_schema %{
    "type" => "integer",
    "description" =>
      "Maximum tokens to return. Defaults to the tool's configured max; " <>
        "capped at 50% of the model's context window. Increase for files " <>
        "you know are large."
  }

  ## --- public entrypoint -----------------------------------------

  def run do
    {base_url, api_key} = read_minimax_provider()
    agents_md = read_agents_md()
    tools = build_tools()

    IO.puts("=" |> String.duplicate(78))
    IO.puts("MiniMax-M3 chat probe — same model, same endpoint, same provider")
    IO.puts("=" |> String.duplicate(78))
    IO.puts("base_url      : #{base_url <> "/chat/completions"}")
    IO.puts("auth          : #{mask(api_key)}")
    IO.puts("model         : #{@model}")
    IO.puts("tools         : #{Enum.map_join(tools, ", ", & &1["function"]["name"])}")
    IO.puts("")

    for {label, opts} <- variants(tools, agents_md) do
      body = build_request_body(opts)
      run_one(label, base_url, api_key, body)
    end

    print_summary()
  end

  ## --- variants --------------------------------------------------

  defp variants(tools, agents_md) do
    [
      {"A — exact Nest request (AGENTS.md, tool_choice=auto)",
       %{
         system: build_system_message(agents_md, include_agents_md?: true),
         tools: tools,
         tool_choice: "auto"
       }},
      {"B — minimal system prompt (no AGENTS.md, tool_choice=auto)",
       %{
         system: build_system_message(agents_md, include_agents_md?: false),
         tools: tools,
         tool_choice: "auto"
       }},
      {"C — exact Nest request but tool_choice=required (force a tool call)",
       %{
         system: build_system_message(agents_md, include_agents_md?: true),
         tools: tools,
         tool_choice: "required"
       }}
    ]
  end

  ## --- request body ----------------------------------------------

  @user_message """
  [mode: plan]
  We were working on notes/subagents.md. What would we need to do to implement that?\
  """

  defp build_request_body(opts) do
    %{
      "model" => @model,
      "messages" => [
        %{"role" => "system", "content" => opts.system},
        %{"role" => "user", "content" => @user_message}
      ],
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "tools" => opts.tools,
      "tool_choice" => opts.tool_choice
    }
  end

  defp build_system_message(agents_md, include_agents_md?: true) do
    vocation_prompt() <>
      mode_catalog() <>
      workspace_section() <>
      tool_call_limit_section() <>
      context_limit_section() <>
      "\n\nHere are AGENTS.md guidelines for this project:\n\n" <> agents_md <> "\n"
  end

  defp build_system_message(_agents_md, include_agents_md?: false) do
    vocation_prompt() <>
      mode_catalog() <>
      workspace_section() <>
      tool_call_limit_section() <>
      context_limit_section()
  end

  defp vocation_prompt do
    """
    You are a skilled programmer. Help users write, review, and understand code.
    You have access to a workspace directory where you can read and write files.
    Use tools to read files and make changes when requested.
    """
  end

  defp mode_catalog do
    """

    [Available modes]

    The user picks a mode per message via the UI. Each mode changes the sandbox profile (filesystem permissions, network access).

    - build: Read only "/". Read and write workspace and /tmp. Network enabled. You're clear to edit the project in the workspace.
    - plan: Read only "/". Read and write /tmp. Network enabled. Read-only planning only, can still run commands.
    """
  end

  defp workspace_section do
    "\n\nWorkspace and tool working directory: #{@workspace}\n"
  end

  defp tool_call_limit_section do
    "\n\nTool call budget: You have a maximum of #{@max_iterations} consecutive tool call rounds per turn.\n"
  end

  defp context_limit_section do
    "\n\nContext limit: #{@context_limit} tokens (resolved from provider_default). " <>
      "You can check current usage via the `context` tool " <>
      "(action: \"check\") and trigger compaction via the `context` " <>
      "tool (action: \"compact\").\n"
  end

  ## --- tool list (matches Nest's `Tools.get_functions/3` output) --

  defp build_tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" => "Read the contents of a file from the workspace",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative path to the file from the workspace root"
              },
              "max_result_tokens" => @max_result_tokens_schema
            },
            "required" => ["path"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "inspect_file",
          "description" =>
            "Inspect a file's metadata (type, encoding, size, line count, " <>
              "char count, max line length, estimated tokens) without reading " <>
              "its contents. Use this before `read_file` to decide whether a " <>
              "full read fits in your context budget, or whether to use " <>
              "`shell_cmd` with `head`, `tail`, or `sed -n` for a partial read. " <>
              "Files larger than 100 MB are rejected; use `shell_cmd` with " <>
              "`wc -l` or `head` for those.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative path to the file from the workspace root"
              },
              "max_result_tokens" => @max_result_tokens_schema
            },
            "required" => ["path"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "write_file",
          "description" => "Write content to a file in the workspace",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative path to the file from the workspace root"
              },
              "content" => %{
                "type" => "string",
                "description" => "Content to write to the file"
              },
              "max_result_tokens" => @max_result_tokens_schema
            },
            "required" => ["path", "content"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "edit",
          "description" =>
            "Perform an exact string replacement in a file. Reads the file, " <>
              "replaces the first (or all) occurrence(s) of `old_text` with " <>
              "`new_text`, and writes it back. With `replace_all: false` " <>
              "(the default), `old_text` must match exactly once or the call fails.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative path to the file from the workspace root"
              },
              "old_text" => %{
                "type" => "string",
                "description" =>
                  "The exact text to find. Must match the file content exactly, " <>
                    "including whitespace and indentation."
              },
              "new_text" => %{
                "type" => "string",
                "description" => "The text to replace `old_text` with."
              },
              "replace_all" => %{
                "type" => "boolean",
                "description" =>
                  "Replace every occurrence of `old_text` instead of just the first. " <>
                    "Default: false. When false, the call errors if `old_text` matches " <>
                    "more than one location.",
                "default" => false
              },
              "max_result_tokens" => @max_result_tokens_schema
            },
            "required" => ["path", "old_text", "new_text"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "shell_cmd",
          "description" => "Execute a shell command and return output",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "command" => %{
                "type" => "string",
                "description" => "Shell command to execute"
              },
              "max_result_tokens" => @max_result_tokens_schema
            },
            "required" => ["command"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "context",
          "description" =>
            "Check current context usage (tokens used, limit, message count) " <>
              "or trigger compaction to free up space.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "action" => %{
                "type" => "string",
                "enum" => ["check", "compact"],
                "description" =>
                  "Action to perform. 'check' returns current context stats. " <>
                    "'compact' triggers compaction to free up context budget."
              },
              "focus" => %{
                "type" => "string",
                "description" =>
                  "When action is 'compact': what to preserve in the summary. " <>
                    "Ignored when action is 'check'."
              },
              "max_result_tokens" => @max_result_tokens_schema
            }
          }
        }
      }
    ]
  end

  ## --- per-variant run -------------------------------------------

  defp run_one(label, base_url, api_key, body) do
    IO.puts("─" |> String.duplicate(78))
    IO.puts(label)
    IO.puts("─" |> String.duplicate(78))
    IO.puts("system prompt bytes : #{byte_size(body["messages"] |> List.first() |> Map.get("content"))}")
    IO.puts("tool_choice         : #{body["tool_choice"]}")
    IO.puts("user message        : #{inspect(body["messages"] |> List.last() |> Map.get("content"))}")
    IO.puts("")

    case stream_sse(base_url, api_key, body) do
      {:ok, events} ->
        print_events(events)

      {:error, reason} ->
        IO.puts("[probe error] #{inspect(reason)}")
    end

    IO.puts("")
  end

  ## --- streaming + SSE parsing -----------------------------------

  defp stream_sse(base_url, api_key, body) do
    url = base_url <> "/chat/completions"

    parent = self()
    parser = init_sse_parser()
    input = {parser, [], parent, []}

    case Req.post(url,
           auth: {:bearer, api_key},
           json: body,
           into: :self,
           receive_timeout: 30_000,
           http_errors: :return,
           max_retries: 0
         ) do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{} = async_body}} ->
        drain_async(async_body, input, :ok)

      {:ok, %Req.Response{status: status, body: body}} ->
        IO.puts("[probe] non-200: status=#{status} body=#{inspect(body, limit: 5)}")
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drain_async(async_body, input, result) do
    try do
      Enum.each(async_body, fn chunk -> send(self(), {:probe_chunk, chunk}) end)
      send(self(), :probe_done)

      # Drain chunks until :probe_done arrives. `Enum.reduce_while`
      # is overkill here; a simple recursive helper is clearer.
      drain_loop(input, result)
    catch
      kind, reason -> {:error, {:transport, kind, reason}}
    end
  end

  defp drain_loop({parser, acc, parent, raw_frames}, result) do
    receive do
      {:probe_chunk, chunk} ->
        IO.puts("    [raw chunk #{byte_size(chunk)} bytes] #{inspect(chunk, limit: 400, printable_limit: 200)}")
        {events, parser} = feed_sse(parser, chunk)
        new_frames = extract_data_frames(chunk)
        drain_loop({parser, acc ++ events, parent, raw_frames ++ new_frames}, result)

      :probe_done ->
        {final_events, _} = flush_sse(parser)
        events = acc ++ final_events
        IO.puts("    [raw frames] #{length(raw_frames)} data frames received")
        send(parent, {:probe_events, events})
        finalize(result, events)
    after
      30_000 ->
        {:error, :inactivity_timeout}
    end
  end

  defp extract_data_frames(chunk) do
    chunk
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "data:"))
  end

  defp finalize(:ok, events), do: {:ok, events}

  ## --- minimal SSE parser ----------------------------------------

  defp init_sse_parser, do: %{buf: "", frames: []}

  defp feed_sse(state, chunk) do
    buf = state.buf <> chunk
    {frames, rest} = split_frames(buf)
    parsed = Enum.flat_map(frames, &parse_frame/1)
    {parsed, %{state | buf: rest}}
  end

  defp flush_sse(state) do
    case state.buf do
      "" -> {[], state}
      _ ->
        frames = String.split(state.buf, "\n\n", trim: true)
        parsed = Enum.flat_map(frames, &parse_frame/1)
        {parsed, %{state | buf: ""}}
    end
  end

  defp split_frames(buf) do
    case :binary.matches(buf, "\n\n") do
      [] ->
        {[], buf}

      positions ->
        {last, _} = List.last(positions)
        complete_len = last + 2
        rest_len = byte_size(buf) - complete_len
        complete = :binary.part(buf, 0, complete_len)
        rest = if rest_len == 0, do: "", else: :binary.part(buf, complete_len, rest_len)
        {String.split(complete, "\n\n", trim: true), rest}
    end
  end

  defp parse_frame(frame) do
    frame
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&String.replace_prefix(&1, "data:", "") |> String.trim_leading())
    |> case do
      ["[DONE]"] -> [{:done, %{response: %{stop_reason: "stop"}}}]
      [data] -> decode_data(data)
      _ -> []
    end
  end

  defp decode_data(""), do: []

  defp decode_data(data) do
    case Jason.decode(data) do
      {:ok, %{"choices" => [_ | _] = choices} = chunk} ->
        choice_events(choices) ++ usage_events(chunk)

      {:ok, %{"error" => err}} ->
        [{:error, err}]

      {:ok, _other} ->
        []

      {:error, %Jason.DecodeError{} = err} ->
        [{:error, {:invalid_json, err, data}}]
    end
  end

  defp choice_events([%{"delta" => delta} = choice | _]) do
    delta_events(delta) ++ finish_event(choice)
  end

  # Walk every present delta field and emit one event per
  # non-empty value. Mirrors `Nest.LLM.OpenAIClient.delta_events/1`
  # so the probe sees exactly what the production parser sees.
  # Order matches the production module: text, thinking, refusal,
  # tool_calls.
  @delta_field_extractors [
    {"content", :text},
    {"reasoning_content", :thinking},
    {"refusal", :refusal},
    {"tool_calls", :tool_calls}
  ]

  defp delta_events(delta) do
    Enum.flat_map(@delta_field_extractors, fn {key, kind} ->
      case Map.get(delta, key) do
        text when is_binary(text) and text != "" and kind != :tool_calls ->
          [{kind, text}]

        calls when is_list(calls) and kind == :tool_calls ->
          Enum.flat_map(calls, &tool_call_event/1)

        _ ->
          []
      end
    end)
  end

  defp tool_call_event(%{"id" => id, "function" => %{"name" => name, "arguments" => args}})
       when is_binary(id) and is_binary(name) and is_binary(args) do
    [
      {:tool_call_start, %{id: id, name: name, index: nil}},
      {:tool_call_delta, %{id: id, arguments_delta: args}}
    ]
  end

  defp tool_call_event(%{"index" => idx, "function" => %{"arguments" => args}})
       when is_binary(args) do
    [{:tool_call_delta, %{id: :by_index, index: idx, arguments_delta: args}}]
  end

  defp tool_call_event(_), do: []

  defp finish_event(%{"finish_reason" => nil}), do: []
  defp finish_event(%{"finish_reason" => reason}), do: [{:finish_reason, reason}]
  defp finish_event(_), do: []

  defp usage_events(%{"usage" => usage}) when is_map(usage) do
    [{:usage, parse_usage(usage)}]
  end

  defp usage_events(_), do: []

  defp parse_usage(usage) do
    total_input = Map.get(usage, "prompt_tokens", 0)
    output = Map.get(usage, "completion_tokens", 0)
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    input = max(total_input - cached, 0)
    reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

    %{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cached,
      reasoning_tokens: reasoning,
      total_tokens: Map.get(usage, "total_tokens", input + output)
    }
  end

  ## --- pretty-print events ---------------------------------------

  defp print_events(events) do
    Enum.each(events, fn
      {:text, text} ->
        IO.puts("  text       : #{inspect(text, limit: 200)}")

      {:thinking, text} ->
        IO.puts("  thinking   : #{inspect(text, limit: 200)}")

      {:tool_call_start, %{name: name}} ->
        IO.puts("  tool_start : name=#{name}")

      {:tool_call_delta, %{arguments_delta: args}} ->
        IO.puts("  tool_args  : #{inspect(args, limit: 200)}")

      {:finish_reason, reason} ->
        IO.puts("  finish     : #{reason}")

      {:usage, usage} ->
        IO.puts("  usage      : input=#{usage.input_tokens} out=#{usage.output_tokens} " <>
                  "reasoning=#{usage.reasoning_tokens} cache_read=#{usage.cache_read_input_tokens} " <>
                  "total=#{usage.total_tokens}")

      {:done, %{response: response}} ->
        IO.puts("  done       : stop_reason=#{inspect(response[:stop_reason])}")

      {:error, reason} ->
        IO.puts("  error      : #{inspect(reason)}")

      other ->
        IO.puts("  other      : #{inspect(other)}")
    end)
  end

  ## --- per-variant summary (printed once at the end) ------------

  defp print_summary do
    # The summary is printed inline by `print_events` for each variant.
    # Below is a recap of the diagnostic matrix.
    IO.puts("=" |> String.duplicate(78))
    IO.puts("Diagnostic matrix")
    IO.puts("=" |> String.duplicate(78))
    IO.puts("""
    | A (exact Nest, tool_choice=auto) | B (no AGENTS.md) | C (tool_choice=required) | Conclusion                                              |
    | think + stop                    | *                | proper tool call         | Model can act; bug = choosing not to under auto         |
    | think + stop                    | proper tool call | proper tool call         | AGENTS.md is the trigger; trim it or modify wording      |
    | think + stop                    | think + stop     | think + stop             | MiniMax-M3 is broken in this prompt context; switch    |
    | proper tool call                | *                | *                        | My analysis was wrong; there's a Nest bug to find       |
    """)
  end

  ## --- helpers ---------------------------------------------------

  defp read_minimax_provider do
    home = Path.expand("~/.config/nest/config.toml")
    {:ok, content} = File.read(home)

    case Regex.run(~r/\[providers\.minimax\]([^[]*)/, content, capture: :all_but_first) do
      [section | _] ->
        key =
          case Regex.run(~r/api-key\s*=\s*"([^"]+)"/, section, capture: :all_but_first) do
            [k] -> k
            _ -> raise "could not find api-key in [providers.minimax]"
          end

        url =
          case Regex.run(~r/base-url\s*=\s*"([^"]+)"/, section, capture: :all_but_first) do
            [u] -> u
            _ -> raise "could not find base-url in [providers.minimax]"
          end

        {url, key}

      nil ->
        raise "could not find [providers.minimax] block in #{home}"
    end
  end

  defp read_agents_md do
    case File.read("AGENTS.md") do
      {:ok, content} -> content
      {:error, reason} -> raise "could not read AGENTS.md: #{inspect(reason)}"
    end
  end

  defp mask(key) do
    String.slice(key, 0, 6) <> "...(#{byte_size(key)} chars)"
  end
end

MiniMaxChatProbe.run()

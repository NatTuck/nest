defmodule Nest.Tools do
  @moduledoc """
  Tool definitions for agent capabilities.

  Each tool is defined as a `Nest.LLM.Tool` that can be executed
  by the agent. Tools are sandboxed to the agent's workspace_path.

  The sandbox's *capability map* (caps) is read from the
  `context` at call time, not captured in the tool closure. This
  means a single tool list works for all modes — the mode's caps
  flow in via the `context` map passed to `Nest.LLM.Tools.execute/3`.
  """

  require Logger

  alias Nest.LLM.Tool
  alias Nest.Tools.ShellCmd

  # Per-tool defaults for `max_result_tokens`. See the plan in
  # `notes/context-and-compaction.md` for the rationale. The
  # `BudgetPlanner` enforces these and may truncate the result
  # before sending it to the LLM. The LLM can override per call.
  @default_max_result_tokens 8192
  @write_file_max_result_tokens 256
  @context_max_result_tokens 512

  @doc """
  Returns a list of `Nest.LLM.Tool` structs for the given tool names.
  """
  @spec get_functions([String.t()], String.t() | nil, String.t() | nil) :: [Tool.t()]
  def get_functions(tool_names, workspace_path, tmp_path \\ nil) do
    tool_names
    |> Enum.map(&get_function(&1, workspace_path, tmp_path))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns a single `Nest.LLM.Tool` for a tool name.
  """
  @spec get_function(String.t(), String.t() | nil, String.t() | nil) :: Tool.t() | nil
  def get_function(name, workspace_path, tmp_path \\ nil) do
    case name do
      "read_file" -> read_file_function(workspace_path, tmp_path)
      "write_file" -> write_file_function(workspace_path, tmp_path)
      "shell_cmd" -> shell_cmd_function(workspace_path, tmp_path)
      "compact_context" -> compact_context_function()
      "context" -> context_function()
      _ -> nil
    end
  end

  defp read_file_function(workspace_path, tmp_path) do
    %Tool{
      name: "read_file",
      description: "Read the contents of a file from the workspace",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative path to the file from the workspace root"
          },
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => ["path"]
      },
      max_result_tokens: @default_max_result_tokens,
      function: fn %{"path" => path}, context ->
        read_file(path, workspace_path, tmp_path, context)
      end
    }
  end

  defp write_file_function(workspace_path, tmp_path) do
    %Tool{
      name: "write_file",
      description: "Write content to a file in the workspace",
      parameters_schema: %{
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
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => ["path", "content"]
      },
      max_result_tokens: @write_file_max_result_tokens,
      function: fn %{"path" => path, "content" => content}, context ->
        write_file(path, content, workspace_path, tmp_path, context)
      end
    }
  end

  defp shell_cmd_function(workspace_path, tmp_path) do
    %Tool{
      name: "shell_cmd",
      description: "Execute a shell command and return output",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to execute"
          },
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => ["command"]
      },
      max_result_tokens: @default_max_result_tokens,
      function: fn %{"command" => command}, context ->
        shell_cmd(command, workspace_path, tmp_path, context)
      end
    }
  end

  # The `compact_context` tool is defined here for the LLM schema,
  # but the actual compaction logic lives in `Nest.Tokens.Compactor`
  # (added in a later step). The function here is a placeholder
  # that the agent intercepts in `handle_chat` before invoking the
  # tool's normal `execute/3` path.
  defp compact_context_function do
    %Tool{
      name: "compact_context",
      description:
        "Replace the conversation history with a summary to free up " <>
          "context budget. Use this when you notice previous tool " <>
          "results were truncated or skipped due to context limits.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "focus" => %{
            "type" => "string",
            "description" =>
              "What to preserve in the summary. Defaults to a " <>
                "balanced summary of all messages."
          },
          "max_result_tokens" => max_result_tokens_schema()
        }
      },
      max_result_tokens: 256,
      function: fn _args, _context ->
        {:ok, "Compaction request received."}
      end
    }
  end

  # The `context` tool provides visibility into context usage and
  # can optionally trigger compaction. Like `compact_context`, the
  # actual execution is intercepted in `ToolLoop` because it needs
  # access to runtime state (messages, context_limit) that the
  # tool function doesn't have.
  defp context_function do
    %Tool{
      name: "context",
      description:
        "Check current context usage (tokens used, limit, message count) " <>
          "or trigger compaction to free up space.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["check", "compact"],
            "description" =>
              "Action to perform. 'check' returns current context stats. " <>
                "'compact' triggers compaction (like compact_context)."
          },
          "focus" => %{
            "type" => "string",
            "description" =>
              "When action is 'compact': what to preserve in the summary. " <>
                "Ignored when action is 'check'."
          },
          "max_result_tokens" => max_result_tokens_schema()
        }
      },
      max_result_tokens: @context_max_result_tokens,
      function: fn _args, _context ->
        {:ok, "Context request received."}
      end
    }
  end

  # JSON schema fragment for the `max_result_tokens` call arg.
  # The LLM sees this on every tool and learns it can request a
  # specific cap; the agent's tool schema layer enforces the 50%
  # context-window ceiling.
  defp max_result_tokens_schema do
    %{
      "type" => "integer",
      "description" =>
        "Maximum tokens to return. Defaults to the tool's configured max; " <>
          "capped at 50% of the model's context window. Increase for files " <>
          "you know are large."
    }
  end

  # Tool implementations

  defp read_file(path, workspace_path, tmp_path, context) do
    caps = caps_from_context(context)
    Logger.info("Tool read_file: #{path} (workspace: #{workspace_path || "none"})")

    # Build the full path - if absolute, use as-is (sandbox will enforce)
    # if relative, join with workspace (requires workspace_path)
    full_path_result =
      if Path.type(path) == :absolute do
        {:ok, path}
      else
        if is_nil(workspace_path) do
          {:error, "No workspace configured for this agent"}
        else
          {:ok, Path.join(workspace_path, path)}
        end
      end

    with {:ok, full_path} <- full_path_result do
      # Use cat via sandboxed shell command to read file
      ShellCmd.execute("cat -- #{shell_escape(full_path)}", workspace_path, tmp_path, caps)
    end
  end

  defp write_file(path, content, workspace_path, tmp_path, context) do
    caps = caps_from_context(context)
    Logger.info("Tool write_file: #{path} (workspace: #{workspace_path || "none"})")

    # Build the full path - if absolute, use as-is (sandbox will enforce)
    # if relative, join with workspace (requires workspace_path)
    full_path_result =
      if Path.type(path) == :absolute do
        {:ok, path}
      else
        if is_nil(workspace_path) do
          {:error, "No workspace configured for this agent"}
        else
          {:ok, Path.join(workspace_path, path)}
        end
      end

    with {:ok, full_path} <- full_path_result do
      # Use cat via sandboxed shell command to write file
      # cat reads from stdin and writes to the specified file
      case ShellCmd.execute(
             "cat > #{shell_escape(full_path)}",
             workspace_path,
             tmp_path,
             caps,
             stdin: content
           ) do
        {:ok, _} ->
          {:ok, "Successfully wrote #{String.length(content)} bytes to #{path}"}

        {:error, reason} ->
          {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  defp shell_cmd(command, workspace_path, tmp_path, context) do
    caps = caps_from_context(context)

    Logger.info(
      "Tool shell_cmd: #{command} (workspace: #{workspace_path || "none"}, tmp: #{tmp_path || "none"})"
    )

    # Execute in sandboxed environment via bwrap + erlexec
    ShellCmd.execute(command, workspace_path, tmp_path, caps)
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: nil

  defp shell_escape(path) do
    # Escape single quotes by ending the quote, adding escaped quote, resuming quote
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end

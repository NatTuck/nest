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
  alias Nest.Tools.InspectFile
  alias Nest.Tools.ShellCmd

  # Per-tool defaults for `max_result_tokens`. See the plan in
  # notes/context-and-compaction.md for the rationale. The
  # `BudgetPlanner` enforces these and may truncate the result
  # before sending it to the LLM. The LLM can override per call.
  @default_max_result_tokens 8192
  @write_file_max_result_tokens 256
  @context_max_result_tokens 512
  @edit_max_result_tokens 256

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
      "edit" -> edit_function(workspace_path, tmp_path)
      "inspect_file" -> inspect_file_function(workspace_path, tmp_path)
      "shell_cmd" -> shell_cmd_function(workspace_path, tmp_path)
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

  # The `edit` tool performs an exact string replacement in a file
  # (Claude Code's Edit semantics). `old_text` must match uniquely
  # unless `replace_all` is true. On mismatch, the tool returns a
  # structured error and the file is left unchanged. The LLM is
  # expected to retry with a more specific `old_text` (or with
  # `replace_all: true` if it really wanted to change every match).
  defp edit_function(workspace_path, tmp_path) do
    %Tool{
      name: "edit",
      description:
        "Perform an exact string replacement in a file. Reads the file, " <>
          "replaces the first (or all) occurrence(s) of `old_text` with " <>
          "`new_text`, and writes it back. With `replace_all: false` " <>
          "(the default), `old_text` must match exactly once or the call fails.",
      parameters_schema: %{
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
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => ["path", "old_text", "new_text"]
      },
      max_result_tokens: @edit_max_result_tokens,
      function: fn args, context ->
        edit(args, workspace_path, tmp_path, context)
      end
    }
  end

  # The `inspect_file` tool returns file metadata (type, size, line
  # count, char count, estimated tokens) for the LLM to plan its
  # context usage. It's strictly read-only: never returns file
  # content, never modifies the file.
  #
  # Workflow it supports: the LLM sees a filename referenced in a
  # task and needs to decide whether to call `read_file` (full
  # content) or use `shell_cmd` with `head`/`tail`/`sed -n` for a
  # partial read. Calling `inspect_file` first gives the size /
  # token estimate so the LLM can pick.
  #
  # Text vs. binary: we trust the `file` command's classification
  # when it says "ASCII text" or starts with "UTF-8", then validate
  # with `String.valid?/1` (since ASCII is a strict subset of
  # UTF-8, valid ASCII is automatically valid UTF-8). Anything
  # else — UTF-16, ISO-8859, PNG, ELF, etc. — is reported as
  # binary with a clear "do not use read_file" hint. We don't try
  # to transcode; the LLM is told to use shell tools for those.
  defp inspect_file_function(workspace_path, tmp_path) do
    InspectFile.build(workspace_path, tmp_path)
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

  # The `context` tool provides visibility into context usage and
  # can optionally trigger compaction. The actual execution is
  # intercepted in `ToolLoop` because it needs access to runtime
  # state (messages, context_limit) that the tool function
  # doesn't have.
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
                "'compact' triggers compaction to free up context budget."
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

  # Edit implementation: read the file (via the same sandboxed cat
  # path as read_file), apply String.replace in Elixir, then write
  # back via the same sandboxed cat path as write_file. Splitting
  # on `old_text` is how we cheaply detect "not found" (parts == 1)
  # and "ambiguous" (parts > 2 with `replace_all: false`).
  defp edit(args, workspace_path, tmp_path, context) do
    path = args["path"]
    old_text = args["old_text"]
    new_text = args["new_text"]
    replace_all = Map.get(args, "replace_all", false)

    caps = caps_from_context(context)
    Logger.info("Tool edit: #{path} (replace_all: #{replace_all})")

    with {:ok, full_path} <- resolve_full_path(path, workspace_path),
         {:ok, current} <- read_file_via_shell(full_path, workspace_path, tmp_path, caps),
         {:ok, replacement_count, updated} <-
           compute_replacement(current, old_text, new_text, replace_all) do
      case ShellCmd.execute(
             "cat > #{shell_escape(full_path)}",
             workspace_path,
             tmp_path,
             caps,
             stdin: updated
           ) do
        {:ok, _} ->
          {:ok, "Replaced #{replacement_count} occurrence(s) in #{path}"}

        {:error, reason} ->
          {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  defp resolve_full_path(path, workspace_path) do
    if Path.type(path) == :absolute do
      {:ok, path}
    else
      if is_nil(workspace_path) do
        {:error, "No workspace configured for this agent"}
      else
        {:ok, Path.join(workspace_path, path)}
      end
    end
  end

  defp read_file_via_shell(full_path, workspace_path, tmp_path, caps) do
    ShellCmd.execute("cat -- #{shell_escape(full_path)}", workspace_path, tmp_path, caps)
  end

  # Returns {:ok, count, new_content} on success, {:error, reason}
  # when old_text is missing or ambiguous (and replace_all is false).
  defp compute_replacement(_current, "", _new_text, _replace_all) do
    {:error, "old_text must be a non-empty string"}
  end

  defp compute_replacement(current, old_text, new_text, true) do
    case count_matches(current, old_text) do
      0 ->
        {:error, "old_text not found in file"}

      count ->
        {:ok, count, String.replace(current, old_text, new_text)}
    end
  end

  defp compute_replacement(current, old_text, new_text, false) do
    parts = String.split(current, old_text)

    case parts do
      [single] when single == current ->
        {:error, "old_text not found in file"}

      [_before, _after] ->
        {:ok, 1, String.replace(current, old_text, new_text, global: false)}

      parts when length(parts) > 2 ->
        {:error,
         "old_text matches #{length(parts) - 1} locations; " <>
           "pass replace_all: true to replace all, or make old_text more specific"}

      _ ->
        # Unreachable given the non-empty `old_text` guard and the
        # cases above; defensive catch-all in case String.split
        # returns an unexpected shape.
        {:error, "old_text not found in file"}
    end
  end

  defp count_matches(content, pattern) do
    case String.split(content, pattern) do
      parts -> max(0, length(parts) - 1)
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

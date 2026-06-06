defmodule Nest.Tools do
  @moduledoc """
  Tool definitions for agent capabilities.

  Each tool is defined as a LangChain.Function that can be executed
  by the LLM. Tools are sandboxed to the agent's workspace_path.
  """

  require Logger

  alias LangChain.Function
  alias Nest.Tools.ShellCmd

  @doc """
  Returns a list of LangChain.Function structs for the given tool names.
  """
  @spec get_functions([String.t()], String.t() | nil, String.t() | nil) :: [Function.t()]
  def get_functions(tool_names, workspace_path, tmp_path \\ nil) do
    tool_names
    |> Enum.map(&get_function(&1, workspace_path, tmp_path))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns a single LangChain.Function for a tool name.
  """
  @spec get_function(String.t(), String.t() | nil, String.t() | nil) :: Function.t() | nil
  def get_function(name, workspace_path, tmp_path \\ nil) do
    case name do
      "read_file" -> read_file_function(workspace_path, tmp_path)
      "write_file" -> write_file_function(workspace_path, tmp_path)
      "shell_cmd" -> shell_cmd_function(workspace_path, tmp_path)
      _ -> nil
    end
  end

  defp read_file_function(workspace_path, tmp_path) do
    Function.new!(%{
      name: "read_file",
      description: "Read the contents of a file from the workspace",
      parameters_schema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Relative path to the file from the workspace root"
          }
        },
        required: ["path"]
      },
      function: fn %{"path" => path}, _context ->
        read_file(path, workspace_path, tmp_path)
      end
    })
  end

  defp write_file_function(workspace_path, tmp_path) do
    Function.new!(%{
      name: "write_file",
      description: "Write content to a file in the workspace",
      parameters_schema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Relative path to the file from the workspace root"
          },
          content: %{
            type: "string",
            description: "Content to write to the file"
          }
        },
        required: ["path", "content"]
      },
      function: fn %{"path" => path, "content" => content}, _context ->
        write_file(path, content, workspace_path, tmp_path)
      end
    })
  end

  defp shell_cmd_function(workspace_path, tmp_path) do
    Function.new!(%{
      name: "shell_cmd",
      description: "Execute a shell command and return output",
      parameters_schema: %{
        type: "object",
        properties: %{
          command: %{
            type: "string",
            description: "Shell command to execute"
          }
        },
        required: ["command"]
      },
      function: fn %{"command" => command}, _context ->
        shell_cmd(command, workspace_path, tmp_path)
      end
    })
  end

  # Tool implementations

  defp read_file(path, workspace_path, tmp_path) do
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
      ShellCmd.execute("cat -- #{shell_escape(full_path)}", workspace_path, tmp_path)
    end
  end

  defp write_file(path, content, workspace_path, tmp_path) do
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
             stdin: content
           ) do
        {:ok, _} ->
          {:ok, "Successfully wrote #{String.length(content)} bytes to #{path}"}

        {:error, reason} ->
          {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  defp shell_cmd(command, workspace_path, tmp_path) do
    Logger.info(
      "Tool shell_cmd: #{command} (workspace: #{workspace_path || "none"}, tmp: #{tmp_path || "none"})"
    )

    # Execute in sandboxed environment via bwrap + erlexec
    ShellCmd.execute(command, workspace_path, tmp_path)
  end

  defp shell_escape(path) do
    # Escape single quotes by ending the quote, adding escaped quote, resuming quote
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end

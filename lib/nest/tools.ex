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
  @spec get_functions([String.t()], String.t() | nil) :: [Function.t()]
  def get_functions(tool_names, workspace_path) do
    tool_names
    |> Enum.map(&get_function(&1, workspace_path))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns a single LangChain.Function for a tool name.
  """
  @spec get_function(String.t(), String.t() | nil) :: Function.t() | nil
  def get_function(name, workspace_path) do
    case name do
      "read_file" -> read_file_function(workspace_path)
      "write_file" -> write_file_function(workspace_path)
      "shell_cmd" -> shell_cmd_function(workspace_path)
      _ -> nil
    end
  end

  defp read_file_function(workspace_path) do
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
        read_file(path, workspace_path)
      end
    })
  end

  defp write_file_function(workspace_path) do
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
        write_file(path, content, workspace_path)
      end
    })
  end

  defp shell_cmd_function(workspace_path) do
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
        shell_cmd(command, workspace_path)
      end
    })
  end

  # Tool implementations

  defp read_file(path, workspace_path) do
    Logger.info("Tool read_file: #{path} (workspace: #{workspace_path || "none"})")

    case resolve_path(path, workspace_path) do
      {:ok, full_path} ->
        case File.read(full_path) do
          {:ok, content} ->
            {:ok, content}

          {:error, reason} ->
            {:error, "Failed to read file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_file(path, content, workspace_path) do
    Logger.info("Tool write_file: #{path} (workspace: #{workspace_path || "none"})")

    case resolve_path(path, workspace_path) do
      {:ok, full_path} ->
        # Ensure parent directory exists
        full_path
        |> Path.dirname()
        |> File.mkdir_p!()

        case File.write(full_path, content) do
          :ok ->
            {:ok, "Successfully wrote #{String.length(content)} bytes to #{path}"}

          {:error, reason} ->
            {:error, "Failed to write file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp shell_cmd(command, workspace_path) do
    Logger.info("Tool shell_cmd: #{command} (workspace: #{workspace_path || "none"})")

    # Execute in sandboxed environment via bwrap + erlexec
    ShellCmd.execute(command, workspace_path)
  end

  # Helper functions

  defp resolve_path(path, workspace_path) when is_binary(workspace_path) do
    # Normalize the path
    normalized = Path.expand(path, "/workspace")

    # Check it's within workspace boundaries
    if String.starts_with?(normalized, "/workspace") do
      # Map /workspace back to actual filesystem path
      relative = Path.relative_to(normalized, "/workspace")
      full_path = Path.join(workspace_path, relative)
      {:ok, full_path}
    else
      {:error, "Path is outside workspace: #{path}"}
    end
  end

  defp resolve_path(_path, nil) do
    {:error, "No workspace configured for this agent"}
  end
end

defmodule Nest.Tools do
  @moduledoc """
  Tool dispatch for agent capabilities.

  Each tool is defined as a `Nest.LLM.Tool` that can be executed
  by the agent. Tools are sandboxed to the agent's workspace_path.

  The sandbox's *capability map* (caps) is read from the
  `context` at call time, not captured in the tool closure. This
  means a single tool list works for all modes — the mode's caps
  flow in via the `context` map passed to `Nest.LLM.Tools.execute/3`.
  """

  require Logger

  alias Nest.LLM.Tool
  alias Nest.Tools.{FileTools, InspectFile, ShellCmd}

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
      "read_file" -> FileTools.read_file_function(workspace_path, tmp_path)
      "write_file" -> FileTools.write_file_function(workspace_path, tmp_path)
      "edit" -> FileTools.edit_function(workspace_path, tmp_path)
      "inspect_file" -> InspectFile.build(workspace_path, tmp_path)
      "shell_cmd" -> shell_cmd_function(workspace_path, tmp_path)
      "context" -> context_function()
      # `clone_agent` is intercepted by the ChatTurn /
      # ToolLoop machinery — the registered tool is just a
      # stub that surfaces in the LLM's tool list with the
      # right schema. The real execution path is
      # `Nest.Agents.Agent.ToolLoop.run_clone_agent/2`,
      # which sends a `clone_agent_request` to the parent
      # GenServer and blocks awaiting the result before
      # returning a synthetic `ToolResult`.
      "clone_agent" -> clone_agent_function()
      _ -> nil
    end
  end

  @doc """
  JSON schema fragment for the `max_result_tokens` call arg.
  The LLM sees this on every tool and learns it can request a
  specific cap. The BatchSizer treats this as an inline-vs-summary
  threshold:

    * `shell_cmd` → if exceeded, write the full output to a
      tmp file and return a path-and-head summary inline.
    * `read_file` → if exceeded, return an error result with
      the actual vs. requested token counts.
    * Other tools → bounded output by construction (cap unreachable).

  The default is 80% of the remaining usable context window.
  The LLM may only lower the cap (e.g. to force a summary/error
  path even when full content fits inline).
  """
  @spec max_result_tokens_schema() :: map()
  def max_result_tokens_schema do
    %{
      "type" => "integer",
      "description" =>
        "Maximum tokens for the inline result. Defaults to 80% of the " <>
          "remaining usable context window. Lower this to force a " <>
          "path-and-head summary (shell_cmd) or an error result " <>
          "(read_file); the value is clamped to the 80% default if you " <>
          "ask for more."
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
      function: fn %{"command" => command}, context ->
        shell_cmd(command, workspace_path, tmp_path, context)
      end
    }
  end

  defp shell_cmd(command, workspace_path, tmp_path, context) do
    caps = caps_from_context(context)

    Logger.info(
      "Tool shell_cmd: #{command} (workspace: #{workspace_path || "none"}, tmp: #{tmp_path || "none"})"
    )

    ShellCmd.execute(command, workspace_path, tmp_path, caps)
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
      function: fn _args, _context ->
        {:ok, "Context request received."}
      end
    }
  end

  # The `clone_agent` tool: spawn a child agent with the
  # full conversation context plus the supplied `instruction`
  # as a new user message; block until the child goes idle;
  # return the child's last assistant message content as the
  # tool result.
  #
  # The `function` here is a stub. The real execution flow
  # lives in `Nest.Agents.Agent.ToolLoop.run_clone_agent/2`
  # (intercepts the tool-call batch and dispatches via
  # `GenServer.call` to the parent Agent GenServer, then
  # `receive`s the forwarded `:clone_agent_result` from the
  # blocking tool worker).
  defp clone_agent_function do
    %Tool{
      name: "clone_agent",
      description:
        "Spawn a child agent with a copy of this conversation. The child " <>
          "runs to completion (it may use other tools, call `clone_agent` itself, " <>
          "or return text) and returns its final assistant message as the tool result. " <>
          "Use this when a task can be delegated without holding the current context.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "instruction" => %{
            "type" => "string",
            "description" =>
              "The task for the child agent to perform. Treated as a new " <>
                "user message after the child's copied message history."
          }
        },
        "required" => ["instruction"]
      },
      function: fn _args, _context ->
        {:ok, "Clone agent request received."}
      end
    }
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: nil
end

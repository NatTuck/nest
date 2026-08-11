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
      "read_file" ->
        FileTools.read_file_function(workspace_path, tmp_path)

      "write_file" ->
        FileTools.write_file_function(workspace_path, tmp_path)

      "edit" ->
        FileTools.edit_function(workspace_path, tmp_path)

      "inspect_file" ->
        InspectFile.build(workspace_path, tmp_path)

      "shell_cmd" ->
        shell_cmd_function(workspace_path, tmp_path)

      "context" ->
        context_function()

      # `clone_agent`, `spawn_agent`, `query_agent`, and
      # `list_agents` are intercepted by the ChatTurn / ToolLoop
      # machinery — the registered tools are stubs that surface
      # the right schema in the LLM's tool list. Real execution
      # lives in `Nest.Agents.Agent.ToolLoop` (clone/spawn route
      # through the agent GenServer; list reads the space inline;
      # query waits on the target's PubSub topic).
      name when name in ["clone_agent", "spawn_agent", "query_agent", "list_agents"] ->
        sub_agent_tool_function(name)

      _ ->
        nil
    end
  end

  # Dispatch the sub-agent tool stubs. Kept as its own function
  # so `get_function/3` stays under the credo cyclomatic-
  # complexity cap.
  defp sub_agent_tool_function("clone_agent"), do: clone_agent_function()
  defp sub_agent_tool_function("spawn_agent"), do: spawn_agent_function()
  defp sub_agent_tool_function("query_agent"), do: query_agent_function()
  defp sub_agent_tool_function("list_agents"), do: list_agents_function()

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

  # The `spawn_agent` tool: create an independent, fresh-context
  # sub-agent in this space with the given `name` and
  # `vocation_id`. Unlike `clone_agent`, the spawned specialist
  # does NOT inherit this conversation — it starts from a fresh
  # system prompt. The coordinator can then talk to it (via a
  # future `query_agent` tool or the normal channel) and list it
  # (`list_agents`).
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop`, which intercepts the batch,
  # sends a `:spawn_agent_request` to the coordinator GenServer,
  # and returns the specialist's name. Spawning is whitelist-
  # checked against the space's blueprint `spawnable_vocation_ids`.
  defp spawn_agent_function do
    %Tool{
      name: "spawn_agent",
      description:
        "Create an independent sub-agent in this space with a fresh context. " <>
          "The specialist starts with only its system prompt (no conversation history). " <>
          "Returns the new agent's name. Spawned vocations may be restricted by this " <>
          "space's blueprint.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The unique name of the new sub-agent within this space."
          },
          "vocation_id" => %{
            "type" => "integer",
            "description" => "The vocation id that defines the specialist's role and tools."
          }
        },
        "required" => ["name", "vocation_id"]
      },
      function: fn _args, _context ->
        {:ok, "Spawn agent request received."}
      end
    }
  end

  # The `list_agents` tool: enumerate the live agents in this
  # space. Returns each agent's name, vocation, status, and
  # depth. Like `spawn_agent`, the `function` here is a stub —
  # `ToolLoop` handles it inline by reading the space's running
  # agents.
  defp list_agents_function do
    %Tool{
      name: "list_agents",
      description:
        "List the running sub-agents in this space, with their name, vocation, " <>
          "status, and depth. Use this to discover agents you can delegate to.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "List agents request received."}
      end
    }
  end

  # The `query_agent` tool: send a chat message to a peer
  # sub-agent in this space and return its final response.
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop.run_query_agent/2`, which
  # subscribes to the target's PubSub topic, triggers its turn
  # via `Agents.chat/3`, and waits for the idle status before
  # returning the target's latest assistant text.
  defp query_agent_function do
    %Tool{
      name: "query_agent",
      description:
        "Send a chat message to a sub-agent in this space and wait for its " <>
          "response. Use this to delegate a question to a specialist you have " <>
          "already spawned (see `spawn_agent` and `list_agents`). Your turn " <>
          "blocks until the target responds.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the sub-agent to query."
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The message to send to the sub-agent."
          }
        },
        "required" => ["name", "prompt"]
      },
      function: fn _args, _context ->
        {:ok, "Query agent request received."}
      end
    }
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: nil
end

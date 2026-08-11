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

      # `agents/spawn`, `agents/query`, `agents/list`, and
      # `agents/archive` are intercepted by the ChatTurn /
      # ToolLoop machinery — the registered tools are stubs
      # that surface the right schema in the LLM's tool list.
      # Real execution lives in `Nest.Agents.Agent.ToolLoop`
      # (spawn/archive route through the agent GenServer; list
      # reads the space inline; query waits on the target's
      # PubSub topic).
      name when name in ["agents/spawn", "agents/query", "agents/list", "agents/archive"] ->
        sub_agent_tool_function(name)

      _ ->
        nil
    end
  end

  # Dispatch the sub-agent tool stubs. Kept as its own function
  # so `get_function/3` stays under the credo cyclomatic-
  # complexity cap.
  defp sub_agent_tool_function("agents/spawn"), do: spawn_agent_function()
  defp sub_agent_tool_function("agents/query"), do: query_agent_function()
  defp sub_agent_tool_function("agents/list"), do: list_agents_function()
  defp sub_agent_tool_function("agents/archive"), do: archive_agent_function()

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

  # The `agents/spawn` tool: the general sub-agent spawn API.
  # Unifies the old `clone_agent` (via `clone_context`) and
  # `spawn_agent`. A child is created in this space and (if
  # `query` is given) immediately asked a task, blocking for its
  # response. `vocation_id` defaults to the parent's vocation;
  # it's only needed to differ. `clone_context: true` inherits
  # the parent's full context (the old `clone_agent` behavior).
  # `archive` (only meaningful with `query`) stops + marks the
  # child archived after its response, making the spawn a
  # one-shot. `timeout` caps how long the call blocks on the
  # query response (default 5 minutes).
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop`, which intercepts the batch,
  # sends a `:spawn_agent_request` to the coordinator GenServer,
  # and returns the child's name (and, if `query` was given, its
  # response). Spawning is whitelist-checked against the space's
  # blueprint `spawnable_vocation_ids`.
  defp spawn_agent_function do
    %Tool{
      name: "agents/spawn",
      description:
        "Create a sub-agent in this space and optionally delegate a task to it. " <>
          "Returns the new agent's name; if `query` is given, additionally blocks " <>
          "and returns the agent's response. `vocation_id` defaults to your own " <>
          "vocation — set it to spawn a specialist with a different role. Set " <>
          "`clone_context` to true to spawn the agent with a copy of this " <>
          "conversation instead of a fresh context. Set `archive` to true (with " <>
          "`query`) to stop and archive the agent after it responds (one-shot). " <>
          "Spawned vocations may be restricted by this space's blueprint.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The unique name of the new sub-agent within this space."
          },
          "vocation_id" => %{
            "type" => "integer",
            "description" =>
              "The vocation id defining the specialist's role and tools. " <>
                "Defaults to your own vocation when omitted."
          },
          "clone_context" => %{
            "type" => "boolean",
            "description" =>
              "When true, spawn the agent with a copy of this conversation " <>
                "instead of a fresh context."
          },
          "query" => %{
            "type" => "string",
            "description" =>
              "When given, sends this as the agent's first task and blocks " <>
                "for its response."
          },
          "archive" => %{
            "type" => "boolean",
            "description" =>
              "When true (with `query`), stop and archive the agent after it " <>
                "responds. Makes the spawn one-shot."
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Maximum milliseconds to block for the response (only used with " <>
                "`query`). Defaults to 300000 (5 minutes)."
          }
        },
        "required" => ["name"]
      },
      function: fn _args, _context ->
        {:ok, "Spawn agent request received."}
      end
    }
  end

  # The `agents/list` tool: enumerate the non-archived agents in
  # this space. Returns each agent's name, vocation, status, and
  # depth. Like `agents/spawn`, the `function` here is a stub —
  # `ToolLoop` handles it inline by reading the space's running
  # agents.
  defp list_agents_function do
    %Tool{
      name: "agents/list",
      description:
        "List the active sub-agents in this space, with their name, vocation, " <>
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

  # The `agents/query` tool: send a chat message to a peer
  # sub-agent in this space and return its final response.
  # `timeout` caps how long the call blocks (default 5 minutes).
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop.run_query_agent/2`, which
  # subscribes to the target's PubSub topic, triggers its turn
  # via `Agents.chat/3`, and waits for the idle status before
  # returning the target's latest assistant text.
  defp query_agent_function do
    %Tool{
      name: "agents/query",
      description:
        "Send a chat message to a sub-agent in this space and wait for its " <>
          "response. Use this to delegate a question to a specialist you have " <>
          "already spawned (see `agents/spawn` and `agents/list`). Your turn " <>
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
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Maximum milliseconds to block for the response. Defaults to " <>
                "300000 (5 minutes)."
          }
        },
        "required" => ["name", "prompt"]
      },
      function: fn _args, _context ->
        {:ok, "Query agent request received."}
      end
    }
  end

  # The `agents/archive` tool: stop + mark an existing agent in
  # this space archived. It is then excluded from `agents/list`
  # and the lobby sidebar, and querying it is an error. Use this
  # to clean up long-lived specialists you're done with.
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop`, which routes through the agent
  # GenServer to stop and archive the target.
  defp archive_agent_function do
    %Tool{
      name: "agents/archive",
      description:
        "Stop and archive a sub-agent in this space. The archived agent is no " <>
          "longer listed or queryable. Use this to clean up a specialist you no " <>
          "longer need.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the sub-agent to archive."
          }
        },
        "required" => ["name"]
      },
      function: fn _args, _context ->
        {:ok, "Archive agent request received."}
      end
    }
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: nil
end

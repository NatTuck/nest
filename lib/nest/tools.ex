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

  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Agents.Agent.Config
  alias Nest.LLM.Tool
  alias Nest.Tokens.ConversationSize
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
      name when name in ["agents-spawn", "agents-query", "agents-list", "agents-archive"] ->
        sub_agent_tool_function(name)

      name ->
        regular_tool_function(name, workspace_path, tmp_path)
    end
  end

  # Dispatch the sub-agent tool stubs. Kept as its own function
  # so `get_function/3` stays under the credo cyclomatic-
  # complexity cap.
  defp sub_agent_tool_function("agents-spawn"), do: spawn_agent_function()
  defp sub_agent_tool_function("agents-query"), do: query_agent_function()
  defp sub_agent_tool_function("agents-list"), do: list_agents_function()
  defp sub_agent_tool_function("agents-archive"), do: archive_agent_function()

  # Dispatch the workspace, shell, and context tools. Kept as its
  # own function so `get_function/3` stays under the credo
  # cyclomatic-complexity cap.
  defp regular_tool_function("file-read", ws, tmp), do: FileTools.read_file_function(ws, tmp)
  defp regular_tool_function("file-write", ws, tmp), do: FileTools.write_file_function(ws, tmp)
  defp regular_tool_function("file-edit", ws, tmp), do: FileTools.edit_function(ws, tmp)
  defp regular_tool_function("file-inspect", ws, tmp), do: InspectFile.build(ws, tmp)
  defp regular_tool_function("shell-cmd", ws, tmp), do: shell_cmd_function(ws, tmp)
  defp regular_tool_function("context-check", _ws, _tmp), do: context_check_function()
  defp regular_tool_function("context-compact", _ws, _tmp), do: context_compact_function()
  defp regular_tool_function(_name, _ws, _tmp), do: nil

  @doc """
  JSON schema fragment for the `max_result_tokens` call arg.
  The LLM sees this on every tool and learns it can request a
  specific cap. The BatchSizer treats this as an inline-vs-summary
  threshold:

    * `shell-cmd` → if exceeded, write the full output to a
      tmp file and return a path-and-head summary inline.
    * `file-read` → if exceeded, return an error result with
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
          "path-and-head summary (shell-cmd) or an error result " <>
          "(file-read); the value is clamped to the 80% default if you " <>
          "ask for more."
    }
  end

  defp shell_cmd_function(workspace_path, tmp_path) do
    %Tool{
      name: "shell-cmd",
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
      "Tool shell-cmd: #{command} (workspace: #{workspace_path || "none"}, tmp: #{tmp_path || "none"})"
    )

    ShellCmd.execute(command, workspace_path, tmp_path, caps)
  end

  # The `context-check` tool reports current context usage. The
  # function receives the live tool context (messages +
  # context_limit) via `BatchSizer.do_execute/2`, and computes
  # real stats using the same math as `CapCalculator`/`BatchSizer`
  # so the LLM is told the exact budget that will be enforced on
  # its tool results.
  defp context_check_function do
    %Tool{
      name: "context-check",
      description:
        "Report current context usage: message count, tokens used vs the limit, " <>
          "percentage used, and usable remaining tokens (after the current messages " <>
          "and the response reserve).",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"max_result_tokens" => max_result_tokens_schema()},
        "required" => []
      },
      function: fn _args, context ->
        context_check(context)
      end
    }
  end

  defp context_check(context) do
    messages = Map.get(context, :messages, [])

    case Map.get(context, :context_limit) do
      limit when is_integer(limit) and limit > 0 ->
        used = ConversationSize.size(messages)
        usable = CapCalculator.usable_remaining(%{context_limit: limit, messages: messages})
        pct = round(used / limit * 100)

        {:ok,
         "Context: #{length(messages)} messages, ~#{round(used)} / #{limit} tokens used " <>
           "(#{pct}%). Usable remaining: ~#{usable} tokens (after current messages + response reserve)."}

      _ ->
        {:ok, "Context: #{length(messages)} messages (limit unknown)."}
    end
  end

  # The `context-compact` tool triggers compaction. It is a
  # control-flow tool: it is intercepted by the ChatTurn response
  # handler (which requires it to be the sole call in a batch) and
  # never actually invoked here, so its `function` is a stub. The
  # schema surfaces the `focus` argument the LLM can pass to guide
  # what the compaction summary should preserve.
  defp context_compact_function do
    %Tool{
      name: "context-compact",
      description:
        "Trigger compaction of the conversation to free up context budget. " <>
          "Must be the sole tool call in its own iteration.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "focus" => %{
            "type" => "string",
            "description" =>
              "What to preserve in the compaction summary (e.g. recent instructions, " <>
                "the current task)."
          }
        },
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "Compaction request received."}
      end
    }
  end

  # The `agents-spawn` tool: the general sub-agent spawn API.
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
      name: "agents-spawn",
      description:
        "Create a sub-agent in this space and optionally delegate a task to it. " <>
          "Returns the new agent's name; if `query` is given, additionally blocks " <>
          "and returns the agent's response. `vocation_id` defaults to your own " <>
          "vocation — set it to spawn a specialist with a different role. Set " <>
          "`clone_context` to true to spawn the agent with a copy of this " <>
          "conversation instead of a fresh context. Set `archive` to true (with " <>
          "`query`) to stop and archive the agent after it responds (one-shot). " <>
          "Spawned vocations may be restricted by this space's blueprint. " <>
          "Sub-agents can be spawned down to a maximum depth of " <>
          "#{Config.configured_max_depth()}.",
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

  # The `agents-list` tool: enumerate the non-archived agents in
  # this space. Returns each agent's name, vocation, status, and
  # depth. Like `agents-spawn`, the `function` here is a stub —
  # `ToolLoop` handles it inline by reading the space's running
  # agents.
  defp list_agents_function do
    %Tool{
      name: "agents-list",
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

  # The `agents-query` tool: send a chat message to a peer
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
      name: "agents-query",
      description:
        "Send a chat message to a sub-agent in this space and wait for its " <>
          "response. Use this to delegate a question to a specialist you have " <>
          "already spawned (see `agents-spawn` and `agents-list`). Your turn " <>
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

  # The `agents-archive` tool: stop + mark an existing agent in
  # this space archived. It is then excluded from `agents-list`
  # and the lobby sidebar, and querying it is an error. Use this
  # to clean up long-lived specialists you're done with.
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop`, which routes through the agent
  # GenServer to stop and archive the target.
  defp archive_agent_function do
    %Tool{
      name: "agents-archive",
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

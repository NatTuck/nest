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
  alias Nest.Sandbox
  alias Nest.Tokens.ConversationSize
  alias Nest.Tools.{FileTools, InspectFile, QueryAgent, ShellJobs, SpawnAgent, WaitAgents}

  @doc """
  Returns a list of `Nest.LLM.Tool` structs for the given tool names.
  """
  @spec get_functions([String.t()], String.t() | nil, String.t() | nil) :: [Tool.t()]
  def get_functions(tool_names, workspace_path, tmp_path \\ nil) do
    tool_names
    |> Enum.map(&resolve_tool(&1, workspace_path, tmp_path))
    |> Enum.reject(&is_nil/1)
  end

  # Resolve a single tool name, logging a warning when the name
  # doesn't correspond to a registered tool (so a vocation that
  # declares an unknown/legacy tool name silently losing it — and
  # potentially ending up with an empty tools list — is visible
  # in the logs instead of surfacing only later as an LLM 400).
  defp resolve_tool(name, workspace_path, tmp_path) do
    case get_function(name, workspace_path, tmp_path) do
      nil ->
        Logger.warning("Unknown tool #{inspect(name)} not registered; skipped")
        nil

      tool ->
        tool
    end
  end

  @doc """
  Returns a single `Nest.LLM.Tool` for a tool name.
  """
  @spec get_function(String.t(), String.t() | nil, String.t() | nil) :: Tool.t() | nil
  def get_function(name, workspace_path, tmp_path \\ nil) do
    case name do
      name
      when name in [
             "agents-spawn",
             "agents-query",
             "agents-list",
             "agents-archive",
             "agents-batch",
             "agents-send",
             "agents-wait",
             "models-list"
           ] ->
        sub_agent_tool_function(name)

      name ->
        regular_tool_function(name, workspace_path, tmp_path)
    end
  end

  # Dispatch the sub-agent tool stubs. Kept as its own function
  # so `get_function/3` stays under the credo cyclomatic-
  # complexity cap.
  defp sub_agent_tool_function("agents-spawn"), do: SpawnAgent.function()
  defp sub_agent_tool_function("agents-query"), do: QueryAgent.function()
  defp sub_agent_tool_function("agents-list"), do: list_agents_function()
  defp sub_agent_tool_function("agents-archive"), do: archive_agent_function()
  defp sub_agent_tool_function("agents-batch"), do: batch_agent_function()
  defp sub_agent_tool_function("agents-send"), do: send_agent_function()
  defp sub_agent_tool_function("agents-wait"), do: WaitAgents.function()

  # Dispatch the models-list tool.
  defp sub_agent_tool_function("models-list"), do: models_list_function()

  # Dispatch the workspace, shell, and context tools. Kept as its
  # own function so `get_function/3` stays under the credo
  # cyclomatic-complexity cap.
  defp regular_tool_function("file-read", ws, tmp), do: FileTools.read_file_function(ws, tmp)
  defp regular_tool_function("file-write", ws, tmp), do: FileTools.write_file_function(ws, tmp)
  defp regular_tool_function("file-edit", ws, tmp), do: FileTools.edit_function(ws, tmp)
  defp regular_tool_function("file-inspect", ws, tmp), do: InspectFile.build(ws, tmp)
  defp regular_tool_function("shell-cmd", ws, tmp), do: shell_cmd_function(ws, tmp)
  defp regular_tool_function("shell-list", _ws, _tmp), do: ShellJobs.list_function()
  defp regular_tool_function("shell-wait", _ws, _tmp), do: ShellJobs.wait_function()
  defp regular_tool_function("shell-kill", _ws, _tmp), do: ShellJobs.kill_function()
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

  @doc """
  The `{space_id, agent_name}` ownership key for the calling agent.

  Tools that manage per-agent resources (background shell jobs) read
  this from the per-call context. The context is supplied by
  `Nest.Agents.Agent.BatchSizer`, which forwards the in-process turn's
  identity; both the writer (`shell-cmd`) and the readers
  (`shell-list`/`shell-wait`/`shell-kill`) must derive it the same way.
  `:unknown` is the defensive fallback for callers without an identity
  (e.g. direct unit tests).
  """
  @spec agent_key(map()) :: {term(), term()}
  def agent_key(context) when is_map(context) do
    {Map.get(context, :space_id, :unknown), Map.get(context, :agent_name, :unknown)}
  end

  defp shell_cmd_function(workspace_path, tmp_path) do
    %Tool{
      name: "shell-cmd",
      description:
        "Execute a shell command and return its output. The command is written " <>
          "to a temporary script and run with bash, so it may span several " <>
          "lines, use heredocs, quotes and metacharacters freely, and run " <>
          "multiple statements in one call. Note there is no implicit `set -e`: " <>
          "a statement that exits non-zero still reports its output and later " <>
          "statements still run, so guard steps explicitly (for example " <>
          "`cmd || exit 1`, or put your own `set -e` on the first line) when a " <>
          "failure must stop the rest.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to execute"
          },
          "background" => %{
            "type" => "boolean",
            "description" =>
              "When true, start the command as a background job and return a job id " <>
                "immediately instead of waiting for output. Manage it with shell-list, " <>
                "shell-wait, and shell-kill. Limited to a small number of concurrent " <>
                "jobs per agent."
          },
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => ["command"]
      },
      function: fn args, context ->
        shell_cmd(args, workspace_path, tmp_path, context)
      end
    }
  end

  defp shell_cmd(%{"command" => command} = args, workspace_path, tmp_path, context) do
    context = context || %{}
    caps = caps_from_context(context)

    Logger.info(
      "Tool shell-cmd: #{command} (workspace: #{workspace_path || "none"}, tmp: #{tmp_path || "none"}, background: #{args["background"] == true})"
    )

    opts = [
      background: args["background"] == true,
      agent_key: agent_key(context),
      agent_pid: Map.get(context, :agent_pid)
    ]

    Sandbox.run(command, workspace_path, tmp_path, caps, opts)
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
  # control-flow tool: it is intercepted by the turn response
  # handler (`Nest.Agents.Agent.Machine.Response`, which requires
  # it to be the sole call in a batch) and
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

  # The `agents-list` tool: enumerate the non-archived agents in
  # this space, whether or not they currently have a live
  # process. Returns each agent's name, vocation, status, and
  # depth. Like `agents-spawn`, the `function` here is a stub —
  # `ToolLoop` handles it inline by reading the space's
  # non-archived agents.
  defp list_agents_function do
    %Tool{
      name: "agents-list",
      description:
        "List the non-archived agents in this space (running or not), with their " <>
          "name, vocation, status, and depth. Use this to discover agents you can " <>
          "delegate to.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"max_result_tokens" => max_result_tokens_schema()},
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "List agents request received."}
      end
    }
  end

  # The `agents-send` tool: asynchronously send a message to another
  # agent in this space. Unlike `agents-query`, it does not wait for a
  # response. If the target is idle the message becomes its next user
  # message (starting a turn); if the target is busy the message is
  # queued, and all queued messages are combined into one user message
  # when the target next goes idle (offloaded to a scratch file when
  # over the configured `max-async-message-tokens` cap).
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop.run_send_agent/2`, which looks up the
  # target agent and hands the message to its GenServer via
  # `Agent.deliver_message/3`.
  defp send_agent_function do
    %Tool{
      name: "agents-send",
      description:
        "Send a message to another agent in this space without waiting for a " <>
          "reply. If that agent is idle the message becomes its next user " <>
          "message; if it is busy the message is queued and delivered together " <>
          "with any other queued messages once it finishes its current turn. " <>
          "Use this to hand off work or share information with a peer or " <>
          "sub-agent; use `agents-query` when you need the response now.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the agent to message."
          },
          "message" => %{
            "type" => "string",
            "description" => "The message to deliver to that agent."
          }
        },
        "required" => ["name", "message"]
      },
      function: fn _args, _context ->
        {:ok, "Send message request received."}
      end
    }
  end

  # The `agents-wait` tool: block until one of the given agents (or,
  # with an empty list, every other agent in this space) finishes its
  # turn and goes idle. The spec lives in `Nest.Tools.WaitAgents` (this
  # file is at the source-file line cap); execution lives in
  # `Nest.Agents.Agent.ToolLoop.run_wait_agents/2`, which delegates to
  # `Nest.Agents.Agent.WaitLoop` in the turn's tool worker.

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

  # The `models-list` tool: list available models from providers
  # that have `expose_models` enabled. Optionally filtered by provider.
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.ToolLoop`, which calls `Models.list/0` and
  # filters by provider and expose_models flag. The output uses the
  # `"provider/model-name"` format that `agents-spawn`'s `model`
  # argument expects.
  defp models_list_function do
    %Tool{
      name: "models-list",
      description:
        "List available models from providers that have expose_models enabled, " <>
          "one \"provider/model-name\" per line. Optionally filter by provider " <>
          "name. Feed the returned strings to `agents-spawn`'s `model` argument.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "provider" => %{
            "type" => "string",
            "description" =>
              "Optional provider name to filter models by. If omitted, returns " <>
                "models from all providers with expose_models enabled."
          },
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "Models list request received."}
      end
    }
  end

  # The `agents-batch` tool: the fork-join sub-agent API. The model
  # makes ONE call that fans a single templated instruction out over a
  # set of items to concurrent sub-agents, and gets back ONE aggregated
  # result (a JSON array of each child's final response, in item order).
  # It never enumerates per-item prompts or tracks child names — that
  # bookkeeping is the runtime's job.
  #
  # Provide `items` (a non-empty list of item strings) OR `glob` (a
  # pattern expanded to readable files, preferred for large sets).
  # `template` (optional) is rendered per item with `{item}` /
  # `{index}`; when omitted the item string itself is the instruction.
  # `archive` defaults to true (children are cleaned up after
  # responding). `max_concurrency` is clamped to a configured ceiling.
  #
  # The `function` here is a stub. Real execution lives in
  # `Nest.Agents.Agent.BatchLoop.run/2`, dispatched from
  # `ToolLoop.run_agents_batch/2`. There is no `required` field — the
  # items/XOR/glob shape is validated at runtime so a descriptive error
  # reaches the model.
  defp batch_agent_function do
    %Tool{
      name: "agents-batch",
      description:
        "Fan ONE instruction out over a set of items to concurrent sub-agents " <>
          "and get back ONE aggregated result: a JSON array of each child's " <>
          "final response string, in item order. Use this instead of many " <>
          "separate agents-spawn calls when every item gets the same task. " <>
          "Provide `items` (a non-empty list) OR `glob` (a pattern expanded " <>
          "to readable files — preferred for large sets, so you never list " <>
          "files by hand). If `template` is given it is rendered per item " <>
          "with {item} and {index}; if omitted, each item is the " <>
          "instruction. `archive` defaults to true. Sub-agents can be " <>
          "spawned down to a maximum depth of " <>
          "#{Config.configured_max_depth()}.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "template" => %{
            "type" => "string",
            "description" =>
              "Optional instruction template, rendered once per item. Must " <>
                "contain {item} or {index} when present. Omit to use each " <>
                "item as its own instruction."
          },
          "items" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The items to fan out over (each becomes one sub-agent). " <>
                "Provide this OR `glob`, not both."
          },
          "glob" => %{
            "type" => "string",
            "description" =>
              "A glob pattern (e.g. \"tests/**/*_test.exs\") expanded to " <>
                "readable regular files, one sub-agent per file. Provide " <>
                "this OR `items`, not both."
          },
          "vocation" => %{
            "type" => "string",
            "description" =>
              "Vocation slug for every child (e.g. \"programmer\"). Defaults to " <>
                "your own vocation (or the space's sole allowed vocation)."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Model for every child as a \"provider/model-name\" string " <>
                "(see `models-list`). Inherits your own model when omitted."
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Per-item milliseconds before a child is abandoned and its " <>
                "result marked as an error. Defaults to 300000 (5 minutes)."
          },
          "archive" => %{
            "type" => "boolean",
            "description" =>
              "When true (the default), stop and archive each child after " <>
                "it responds."
          },
          "name_prefix" => %{
            "type" => "string",
            "description" =>
              "Optional constant prefix prepended to each child's name. " <>
                "Children are named from their item (`<prefix>-<item>`), with " <>
                "`-1`/`-2` appended when the same item repeats."
          },
          "max_concurrency" => %{
            "type" => "integer",
            "description" =>
              "Maximum children to run at once for this call. Clamped to a " <>
                "configured ceiling. The default is typically fine."
          },
          "on_error" => %{
            "type" => "string",
            "enum" => ["collect", "fail_fast"],
            "description" =>
              "\"collect\" (default) keeps a failed/timed-out item as an " <>
                "error marker in its slot and still returns the rest; " <>
                "\"fail_fast\" stops at the first failure."
          },
          "max_result_tokens" => max_result_tokens_schema()
        },
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "Batch agents request received."}
      end
    }
  end

  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: Nest.Sandbox.default_caps()
end

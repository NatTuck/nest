defmodule Nest.Tools.Pane do
  @moduledoc """
  The `pane` tool group (issues #119 and #120): the decision queue an agent
  asks the user to answer, and the TODO list it keeps for the user to watch.

  The pane itself is `Nest.Agents.Agent.Pane`, a per-space manager; these tools
  read the calling agent's `{space_id, agent_name}` from the per-call context
  (as `Nest.Tools.ShellJobs` does) so every write is scoped to the agent that
  made it. All five are **non-blocking**: `decisions-ask` files a question and
  the answer arrives later as an ordinary message, so no tool here waits for
  the user. An agent that waits for an answer burns its turn.
  """

  alias Nest.Agents.Agent.Pane, as: PaneStore
  alias Nest.LLM.Tool

  @option_schema %{
    "type" => "string",
    "description" => "One suggested answer. The user can also type their own."
  }

  @todo_schema %{
    "type" => "object",
    "properties" => %{
      "text" => %{"type" => "string", "description" => "What the step is."},
      "status" => %{
        "type" => "string",
        "enum" => ~w(pending in_progress done),
        "description" => "Where the step stands right now."
      }
    },
    "required" => ["text", "status"]
  }

  @doc "The `decisions-ask` tool: put a question in the user's pane."
  @spec ask_function() :: Tool.t()
  def ask_function do
    %Tool{
      name: "decisions-ask",
      description:
        "Add a question for the user to the right-hand pane, with a title, a " <>
          "body explaining the context and tradeoffs, and 2 to 5 suggested " <>
          "answers (the user can also type their own). The user answers later, " <>
          "as a message to you — this call returns immediately and you should " <>
          "NOT wait for an answer; keep working. Ask a question when you need a " <>
          "decision that is the user's to make, not for something you can " <>
          "settle yourself. The question stays in the pane until the user " <>
          "answers or drops it.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{
            "type" => "string",
            "description" => "The question, in one line. Shown collapsed in the pane."
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "The context and the tradeoffs: what the choice is about and what " <>
                "each answer would mean."
          },
          "options" => %{
            "type" => "array",
            "items" => @option_schema,
            "minItems" => 2,
            "maxItems" => 5,
            "description" => "The suggested answers, 2 to 5 of them."
          }
        },
        "required" => ["title", "body", "options"]
      },
      function: fn args, context -> ask(args, context) end
    }
  end

  @doc "The `decisions-list` tool: the space's open questions."
  @spec list_function() :: Tool.t()
  def list_function do
    %Tool{
      name: "decisions-list",
      description:
        "List the questions currently in the user's pane for this space: each " <>
          "one's id, title, the agent that asked it, and whether it has been " <>
          "marked obsolete or orphaned. Read-only. The user answers them " <>
          "later, as messages.",
      parameters_schema: %{"type" => "object", "properties" => %{}, "required" => []},
      function: fn _args, context -> list(context) end
    }
  end

  @doc "The `decisions-obsolete` tool: mark a question as no longer needed."
  @spec obsolete_function() :: Tool.t()
  def obsolete_function do
    %Tool{
      name: "decisions-obsolete",
      description:
        "Mark one of your questions as no longer needed, with a reason. It " <>
          "stays in the user's pane — this never removes it and never reorders " <>
          "anything — and the user decides whether to drop it. Use this when " <>
          "you have answered the question yourself or it no longer matters.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "The decision id, e.g. \"d1\"."},
          "reason" => %{
            "type" => "string",
            "description" => "Why it is no longer needed, shown to the user."
          }
        },
        "required" => ["id", "reason"]
      },
      function: fn args, context -> obsolete(args, context) end
    }
  end

  @doc "The `todos-write` tool: replace this agent's TODO list."
  @spec todos_write_function() :: Tool.t()
  def todos_write_function do
    %Tool{
      name: "todos-write",
      description:
        "Replace your TODO list in the user's right-hand pane with the list " <>
          "given here. There are no ids and no per-item updates: send the whole " <>
          "list every time, in the order you will work through it, and mark " <>
          "each step pending, in_progress or done. Keep it short — it is the " <>
          "user's view of what you are doing, not a plan document.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "items" => %{
            "type" => "array",
            "items" => @todo_schema,
            "description" => "The whole list, in order."
          }
        },
        "required" => ["items"]
      },
      function: fn args, context -> write_todos(args, context) end
    }
  end

  @doc "The `todos-list` tool: this agent's TODO list."
  @spec todos_list_function() :: Tool.t()
  def todos_list_function do
    %Tool{
      name: "todos-list",
      description: "List your TODO list as the user's pane shows it.",
      parameters_schema: %{"type" => "object", "properties" => %{}, "required" => []},
      function: fn _args, context -> todos_list(context) end
    }
  end

  # ---- Implementations ----

  defp ask(args, context) do
    with_agent(context, fn space_id, name ->
      case PaneStore.ask(space_id, name, args["title"], args["body"], args["options"]) do
        {:ok, id} ->
          {:ok,
           "Decision #{id} is now in the user's pane. The user will answer it later, " <>
             "as a message — do not wait for it. Keep working."}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp list(context) do
    with_agent(context, fn space_id, _name ->
      case PaneStore.decisions(space_id) do
        [] -> {:ok, "No open decisions."}
        decisions -> {:ok, Enum.map_join(decisions, "\n", &render_decision/1)}
      end
    end)
  end

  defp render_decision(decision) do
    "- #{decision.id}: #{decision.title} (asked by #{decision.asked_by})" <>
      flags(decision)
  end

  defp flags(decision) do
    [
      decision.obsolete? && " [obsolete: #{decision.obsolete_reason}]",
      decision.orphaned? && " [orphaned: #{decision.orphaned_reason}]"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp obsolete(args, context) do
    with_agent(context, fn space_id, _name ->
      case PaneStore.mark_obsolete(space_id, args["id"], args["reason"]) do
        :ok ->
          {:ok,
           "Decision #{args["id"]} marked obsolete. It stays in the user's pane; " <>
             "the user decides whether to drop it."}

        {:error, :not_found} ->
          {:error, "No such decision: #{args["id"]}"}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp write_todos(%{"items" => items}, context) do
    with_agent(context, fn space_id, name ->
      case PaneStore.write_todos(space_id, name, items) do
        :ok -> {:ok, "TODO list updated (#{length(items)} item(s))."}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp write_todos(_args, _context) do
    {:error, "The `items` argument must be a list of {text, status} entries."}
  end

  defp todos_list(context) do
    with_agent(context, fn space_id, name ->
      case PaneStore.todos(space_id, name) do
        [] -> {:ok, "Your TODO list is empty."}
        items -> {:ok, Enum.map_join(items, "\n", &"- [#{&1.status}] #{&1.text}")}
      end
    end)
  end

  # The pane is keyed by the *real* agent: a tool call with no identity would
  # otherwise write to a bucket nothing ever reads.
  defp with_agent(context, fun) do
    case Nest.Tools.agent_key(context) do
      {space_id, name} when is_integer(space_id) and is_binary(name) -> fun.(space_id, name)
      _key -> {:error, "This tool needs a running agent's identity."}
    end
  end
end

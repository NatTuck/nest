# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: uses `Vocations.upsert_vocation/1` so re-running
# this script updates existing rows (system prompts, modes,
# tools) in place rather than failing on duplicate names or
# creating a second row. Safe to re-run after editing any
# vocation field below.
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Nest.Repo.insert!(%Nest.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Nest.Blueprints
alias Nest.Vocations

# Any vocation that gets any `agents/*` tool gets all of them
# (`agents/spawn`, `agents/query`, `agents/list`,
# `agents/archive`). `agents/spawn` is additionally stripped for
# max-depth agents at spawn/compaction time (the others remain).
agents_tools = ["agents/spawn", "agents/query", "agents/list", "agents/archive"]

# Default - minimal vocation for agents without a specific role.
# Used as the fallback for any test or runtime path that needs a
# vocation but doesn't care which one. Single "chat" mode with the
# `context` tool only (no filesystem, no network).
{:ok, default_vocation} =
  Vocations.upsert_vocation(%{
    name: "Default",
    description: "A minimal default vocation for agents without a specific role",
    system_prompt: "You are a helpful assistant.",
    tools: ["context" | agents_tools],
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => false,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

# Programmer - code-focused agent with tools and workspace.
# Two modes:
#   - "build": can read/write the workspace, run shell commands,
#              and access the network (for fetching docs, packages, etc.)
#   - "plan":  read-only; explore the workspace without making changes
# Network is enabled in both modes.
{:ok, programmer_vocation} =
  Vocations.upsert_vocation(%{
    name: "Programmer",
    description: "A coding assistant that can read and write files in a workspace",
    system_prompt: """
    You are a skilled programmer. Help users write, review, and understand code.
    You have access to a workspace directory where you can read and write files.
    Use tools to read files and make changes when requested.

    Actively manage your context. Prefer reading entire files that are relevent to
    your task once if they can all fit in context. Make effient use of shell commands
    to analyze and modify files in the project.

    You can assume you're running on a typical Linux system and that ripgrep is installed
    as `rg`. 

    The "shell_cmd" tool will automatically save long outputs to a file. Use the 
    "max_result_tokens" parameter to control when this happens and avoid wasting context
    on large shell command outputs. Use this mechanism instead of throwing away potentially
    useful outputs with head, tail, grep, or similar for commands that cost significant time
    or access remote APIs.
    """,
    tools: [
      "read_file",
      "inspect_file",
      "write_file",
      "edit",
      "shell_cmd",
      "context",
      "agents/spawn",
      "agents/query",
      "agents/list",
      "agents/archive"
    ],
    modes: %{
      "build" => %{
        "description" => """
        You have write access to the workspace. You can make modifications as appropriate. Don't make extra changes the user didn't request.
        """,
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      },
      "plan" => %{
        "description" => """
        You have read-only access to the workspace. You are free to make tool calls, but workspace writes will fail because you're supposed to
        be inspecting the workspace but not changing it right now.
        """,
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

# ---- Role vocations ----
# Beyond the minimal `Default` fallback, every root vocation gets
# the full toolset. `Chat` is deliberately minimal (conversation
# only), matching the old default-agent behavior.

all_tools =
  [
    "read_file",
    "inspect_file",
    "write_file",
    "edit",
    "shell_cmd",
    "context"
  ] ++ agents_tools

minimal_tools = ["context" | agents_tools]

# Chat — general-purpose conversation with no filesystem/network.
{:ok, chat_vocation} =
  Vocations.upsert_vocation(%{
    name: "Chat",
    description: "A general-purpose conversational agent.",
    system_prompt: "You are a helpful assistant.",
    tools: minimal_tools,
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => false,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

# Code Review Coordinator — reviews code, spawns specialist reviewers.
{:ok, code_review_vocation} =
  Vocations.upsert_vocation(%{
    name: "Code Review Coordinator",
    description: "A coordinator that reviews code and spawns specialist reviewers.",
    system_prompt:
      "You are a code review coordinator. Coordinate reviewers and synthesize their findings.",
    tools: all_tools,
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      }
    }
  })

# Game Master — runs a tabletop RPG campaign.
{:ok, game_master_vocation} =
  Vocations.upsert_vocation(%{
    name: "Game Master",
    description: "A game master that runs tabletop RPG campaigns.",
    system_prompt:
      "You are a tabletop RPG game master. Narrate the world, run NPCs, and arbitrate the rules.",
    tools: all_tools,
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      }
    }
  })

# Grading Coordinator — grades work and spawns specialist graders.
{:ok, grading_vocation} =
  Vocations.upsert_vocation(%{
    name: "Grading Coordinator",
    description: "A coordinator that grades submissions and spawns specialist graders.",
    system_prompt:
      "You are a grading coordinator. Coordinate graders and synthesize their assessments.",
    tools: all_tools,
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      }
    }
  })

# ---- Blueprints ----
# Each blueprint pins a root vocation (so the space's first
# agent starts with the right role) and lists vocations the
# space's agents are allowed to spawn. `spawnable_vocation_ids: []`
# means unrestricted. `workspace_template` and `main_view_config`
# ship as empty maps for now.

chat_vid = chat_vocation.id
programmer_vid = programmer_vocation.id
code_review_vid = code_review_vocation.id
game_master_vid = game_master_vocation.id
grading_vid = grading_vocation.id

# The old "Agent" blueprint (rooted in `Default`) is obsolete —
# the default set is now the five role blueprints below. Delete it
# so it no longer appears in the picker.
case Blueprints.get_by_slug("agent") do
  nil -> :ok
  %Nest.Blueprints.Blueprint{} = blueprint -> Blueprints.delete_blueprint(blueprint)
end

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Chat",
    description: "A single-agent conversational space.",
    root_vocation_id: chat_vid,
    spawnable_vocation_ids: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Coding",
    description: "A coding agent that reads and writes a workspace.",
    root_vocation_id: programmer_vid,
    spawnable_vocation_ids: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Code Review",
    description: "A coordinator that reviews code with specialist sub-agents.",
    root_vocation_id: code_review_vid,
    spawnable_vocation_ids: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Tabletop RPG",
    description: "A game master that runs a tabletop RPG campaign.",
    root_vocation_id: game_master_vid,
    spawnable_vocation_ids: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Grading",
    description: "A coordinator that grades submissions with specialist sub-agents.",
    root_vocation_id: grading_vid,
    spawnable_vocation_ids: []
  })

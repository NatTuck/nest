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

alias Nest.Vocations

# Default - minimal vocation for agents without a specific role.
# Used as the fallback for any test or runtime path that needs a
# vocation but doesn't care which one. Single "chat" mode with the
# `context` tool only (no filesystem, no network).
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Default",
    description: "A minimal default vocation for agents without a specific role",
    system_prompt: "You are a helpful assistant.",
    tools: ["context", "clone_agent"],
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
{:ok, _} =
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
      "clone_agent"
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

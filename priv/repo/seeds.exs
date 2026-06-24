# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Nest.Repo.insert!(%Nest.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Nest.Vocations

# Chat Buddy - simple chat agent, no tools.
# One mode ("chat") which uses the default caps (no filesystem, no net).
{:ok, _} =
  Vocations.create_vocation(%{
    name: "Chat Buddy",
    description: "A friendly chat companion for general conversation",
    system_prompt:
      "You are a helpful and friendly chat companion. Engage in natural conversation and provide thoughtful responses.",
    tools: ["context"],
    modes: %{
      "chat" => %{
        "description" =>
          "General conversation. The `context` tool can check usage or compact the history.",
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
  Vocations.create_vocation(%{
    name: "Programmer",
    description: "A coding assistant that can read and write files in a workspace",
    system_prompt: """
    You are a skilled programmer. Help users write, review, and understand code.
    You have access to a workspace directory where you can read and write files.
    Use tools to read files and make changes when requested.
    """,
    tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
    modes: %{
      "build" => %{
        "description" => "You're clear to edit the project in the workspace.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      },
      "plan" => %{
        "description" => "Read-only planning only, can still run commands.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

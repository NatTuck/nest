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

# Chat Buddy - simple chat agent, no tools
{:ok, _} =
  Vocations.create_vocation(%{
    name: "Chat Buddy",
    description: "A friendly chat companion for general conversation",
    system_prompt:
      "You are a helpful and friendly chat companion. Engage in natural conversation and provide thoughtful responses.",
    tools: [],
    modes: %{
      "chat" => %{
        "net" => false,
        "fs" => %{"read" => [], "write" => []}
      }
    }
  })

# Programmer - code-focused agent with tools and workspace
{:ok, _} =
  Vocations.create_vocation(%{
    name: "Programmer",
    description: "A coding assistant that can read and write files in a workspace",
    system_prompt:
      "You are a skilled programmer. Help users write, review, and understand code. You have access to a workspace directory where you can read and write files. Use tools to read files and make changes when requested.",
    tools: ["read_file", "write_file", "shell_cmd"],
    modes: %{
      "plan" => %{
        "net" => true,
        "fs" => %{"read" => [":workspace"], "write" => []}
      },
      "build" => %{
        "net" => true,
        "fs" => %{"read" => [":workspace"], "write" => [":workspace"]}
      }
    }
  })

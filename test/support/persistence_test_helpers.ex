defmodule Nest.PersistenceTestHelpers do
  @moduledoc """
  Test helpers for the persistence test suites. Lazily creates
  a single `:nest_persistence_test_vocation_id` per test
  process (matches the original test file's Process.get/put
  pattern) so every `agent_attrs/1` call returns a valid
  vocation_id without re-upserting.

  Also lazily creates a `:nest_persistence_test_space_id` per
  test process and stashes it in the agent attrs so callers
  don't have to thread `space_id` through every fixture.
  """

  alias Nest.Spaces
  alias Nest.Vocations

  def agent_attrs(name) do
    %{
      space_id: test_space_id(),
      name: name,
      model: %{name: "test-model", provider: "test"},
      workspace_path: nil,
      vocation_id: test_vocation_id()
    }
  end

  def test_space_id do
    case Process.get(:nest_persistence_test_space_id) do
      nil ->
        {:ok, space} =
          Spaces.create_space(nil, %{
            name: "persistence-test-space-#{System.unique_integer([:positive])}",
            slug: "persistence-test-space-#{System.unique_integer([:positive])}"
          })

        Process.put(:nest_persistence_test_space_id, space.id)
        space.id

      id ->
        id
    end
  end

  def test_vocation_id do
    case Process.get(:nest_persistence_test_vocation_id) do
      nil ->
        {:ok, %Vocations.Vocation{id: id}} =
          Vocations.upsert_vocation(%{
            name: "Persistence Test Default",
            description: "Default for persistence tests",
            system_prompt: "You are a helpful test assistant.",
            tools: ["context-check", "context-compact"],
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

        Process.put(:nest_persistence_test_vocation_id, id)
        id

      id ->
        id
    end
  end
end

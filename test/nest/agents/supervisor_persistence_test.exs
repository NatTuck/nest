defmodule Nest.Agents.SupervisorPersistenceTest do
  @moduledoc """
  Regression tests for `Supervisor.get_agent/1` with persistence enabled.

  These tests must use `Nest.DataCase` (a sandboxed connection)
  because they exercise the DB-backed on-demand-load path. Kept
  in a separate file from `supervisor_test.exs` so the
  in-process `Registry`-only tests in that file can stay
  `async: true`.

  The regressed production crash was:
    AgentChannel.join("agent:" <> name)
      → Agents.get_agent(name)
      → Supervisor.get_agent(name)
      → Supervisor.fetch_or_start_agent(%{name: name})    # only :name
      → do_fetch_or_start_with_persistence/1
      → safe_fetch_for_start(name) → {:error, :not_found}
      → do_insert_and_start(%{name: name}, 1)              # no :model
      → Persistence.insert_agent(%{name: name})
      → Map.fetch!(attrs, :model)                          # KeyError

  The fix returns `:not_found` from `do_fetch_or_start_with_persistence/1`
  when an explicit name has no DB row, instead of falling through
  to `do_insert_and_start/2` with a partial attrs map.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Vocations

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    :ok
  end

  defp test_vocation_id do
    {:ok, %Vocations.Vocation{id: id}} =
      Vocations.upsert_vocation(%{
        name: "Supervisor Persistence Test Default",
        description: "Default for supervisor persistence tests",
        system_prompt: "You are a helpful test assistant.",
        tools: ["context"],
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

    id
  end

  describe "get_agent/1" do
    test "returns :not_found (not a crash) for an explicit name not in the DB" do
      name = "missing-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} =
               Supervisor.get_agent(AgentTestHelpers.current_space_id(), name)
    end

    test "starts the agent when the row is in the DB but not in the Registry" do
      name = "rebuilt-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Persistence.insert_agent(%{
          space_id: AgentTestHelpers.current_space_id(),
          name: name,
          model: %{name: "qwen3.5-plus"},
          vocation_id: test_vocation_id()
        })

      # `Supervisor.fetch_or_start_agent/1` (under
      # `Supervisor.get_agent/1`) lazily starts the BEAM pid
      # on the registry lookup. Without `ensure_cleanup/1`,
      # the pid would persist into other parallel tests'
      # scope — the registry holds a reference, the test pid
      # has exited, and any subsequent DB call by the agent
      # fails with `DBConnection.OwnershipError`.
      AgentTestHelpers.ensure_cleanup(name)

      assert {:ok, pid} = Supervisor.get_agent(AgentTestHelpers.current_space_id(), name)
      assert is_pid(pid)
      assert Process.alive?(pid)

      Agents.delete_agent(AgentTestHelpers.current_space_id(), name)
    end
  end
end

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
  use Nest.DataCase, async: false

  alias Nest.Agents
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Vocations

  setup do
    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)
    on_exit(fn -> Application.put_env(:nest, :persistence, previous) end)
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
      assert {:error, :not_found} = Supervisor.get_agent(name)
    end

    test "starts the agent when the row is in the DB but not in the Registry" do
      name = "rebuilt-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Persistence.insert_agent(%{
          name: name,
          model: %{name: "qwen3.5-plus"},
          vocation_id: test_vocation_id()
        })

      assert {:ok, pid} = Supervisor.get_agent(name)
      assert is_pid(pid)
      assert Process.alive?(pid)

      Agents.delete_agent(name)
    end
  end
end

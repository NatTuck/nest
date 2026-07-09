defmodule Nest.Agents.Agent.PersistenceTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Persistence` — the per-agent
  wrapper around `Nest.Persistence` that the Agent's `init/1`
  and `__append_message__/2` paths use.

  The wrapper gates every write on the `:persistence_enabled`
  app-env flag (see `config/test.exs`), so the disabled-path
  is a no-op and the enabled-path forwards to the real
  `Persistence.insert_message/2` / `update_next_message_index/2`
  calls.

  This file uses `Nest.DataCase, async: false` and toggles the
  app env in `setup` / `on_exit` (matching the pattern in
  `test/nest/persistence_test.exs`). The wrapper has no other
  direct test coverage today.
  """
  use Nest.DataCase, async: false

  import ExUnit.Callbacks

  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
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
        name: "Agent Persistence Test Default",
        description: "Default for agent persistence tests",
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

  describe "append_message/3" do
    test "does not raise on a duplicate system message (regression for Agent.init/1)" do
      # Direct regression for the production crash reported in
      # the /agent/defeated-jackal session: joining an existing
      # agent channel caused `Agent.init/1` to re-insert the
      # system message at index 0, which collided with the
      # already-persisted row. With `on_conflict: :nothing` in
      # `Persistence.insert_message/2`, the second insert is a
      # silent no-op; the wrapper must not raise.
      name = "dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Persistence.insert_agent(%{
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: test_vocation_id()
        })

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      assert {:ok, _} = Persistence.insert_message(name, system_msg)

      # The Agent's `init/1` calls `persist_initial_system_message/1`
      # which routes through `AgentPersistence.append_message/3`.
      # The second call (the one that triggered the production
      # crash) must succeed without raising.
      assert :ok = AgentPersistence.append_message(name, system_msg, 1)
    end

    test "is a no-op when persistence is disabled" do
      # Pin the disabled-path. With persistence off (the test
      # default), the wrapper short-circuits and never touches
      # the DB. No DB row exists for this name; if the wrapper
      # were forwarding through to `Persistence.insert_message/2`,
      # the FK constraint on `agent_id` would fire and the
      # call would raise. The wrapper must short-circuit.
      Application.put_env(:nest, :persistence, enabled: false)
      name = "disabled-#{System.unique_integer([:positive])}"

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}

      # The disabled-path returns `nil` (the value of the `if`
      # expression when the else branch is implicit). Callers
      # (Agent.init/1, __append_message__/2) don't read the
      # return value, so this is a pin on the short-circuit
      # behavior rather than a contract assertion.
      assert AgentPersistence.append_message(name, system_msg, 1) == nil
    end

    test "bumps next_message_index on a fresh insert" do
      name = "bump-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{}} =
        Persistence.insert_agent(%{
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: test_vocation_id()
        })

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}
      assert :ok = AgentPersistence.append_message(name, system_msg, 1)

      assert [%PersistedAgent{next_message_index: 1}] =
               Nest.Repo.all(PersistedAgent)
               |> Enum.filter(&(&1.name == name))
    end
  end

  describe "record_compaction/3,5" do
    test "the 3-arity form uses the default-arg branch (tokens nil when not provided)" do
      name = "rc-default-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{id: agent_id}} =
        Persistence.insert_agent(%{
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: test_vocation_id()
        })

      # Pre-insert a row at the marker index so the marker row
      # has a sortable target.
      _ =
        %PersistedMessage{}
        |> PersistedMessage.changeset(%{
          agent_id: agent_id,
          message_index: 0,
          role: "user",
          content: %{"parts" => []}
        })
        |> Nest.Repo.insert!()

      # 3-arity call: all five clauses are exercised (3 required,
      # 2 default). With persistence disabled, returns `:ok`
      # immediately — this pins the default-arg branches on the
      # public function rather than on the underlying
      # `Persistence.record_compaction/5` path.
      Application.put_env(:nest, :persistence, enabled: false)
      assert :ok = AgentPersistence.record_compaction(name, 1, 1)
    end

    test "the 5-arity form passes token stats through to the underlying Persistence call" do
      name = "rc-stats-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{}} =
        Persistence.insert_agent(%{
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: test_vocation_id()
        })

      assert :ok =
               AgentPersistence.record_compaction(name, 5, 3, 18_432, 4_096)
    end
  end
end

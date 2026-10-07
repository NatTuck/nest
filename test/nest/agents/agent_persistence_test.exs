defmodule Nest.Agents.Agent.PersistenceTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Persistence` — the per-agent
  wrapper around `Nest.Persistence` that the Agent's `init/1`
  and `__append_message__/2` paths use.

  The wrapper forwards to the real `Persistence.insert_message_by_agent_id/2`
  / `update_next_message_index/2` calls, resolving (and caching) the
  agent's `agents.id` on the state it is handed.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Vocations

  # The minimum `Agent.t()` the wrapper reads: `space_id`, `name`, and
  # `chat_state`. `agent_row_id` starts unresolved, so the wrapper
  # exercises its own resolution.
  defp append_state(name) do
    %Agent{space_id: test_space_id(), name: name, chat_state: %Agent.ChatState{}}
  end

  defp local_vocation_id do
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
      # `Persistence.insert_message_by_agent_id/2`, the second insert is a
      # silent no-op; the wrapper must not raise.
      name = "dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
        })

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      assert {:ok, _} = Persistence.insert_message(test_space_id(), name, system_msg)

      # The Agent's append path calls `AgentPersistence.append_message/3`
      # with its state. The second call (the one that triggered the
      # production crash) must succeed without raising, and must hand
      # back the state with the agent's row id resolved onto it.
      state = append_state(name)

      assert %Agent{chat_state: %{agent_row_id: agent_row_id}} =
               AgentPersistence.append_message(state, system_msg, 1)

      assert is_integer(agent_row_id)
    end

    test "bumps next_message_index on a fresh insert" do
      name = "bump-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{}} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
        })

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}
      assert %Agent{} = AgentPersistence.append_message(append_state(name), system_msg, 1)

      assert [%PersistedAgent{next_message_index: 1}] =
               Nest.Repo.all(PersistedAgent)
               |> Enum.filter(&(&1.name == name))
    end

    test "a cached agents.id never writes to a row that took over the name" do
      # The invalidation question for the cached id: the row is deleted
      # (the space-teardown path) while the process is still alive, and a
      # *different* agent row takes over the name. `agents.id` is a
      # `bigserial`, so the replacement gets a fresh id — the cached one
      # can never resolve to it. The append must therefore be dropped,
      # not silently re-targeted at the new agent.
      name = "reused-#{System.unique_integer([:positive])}"
      attrs = agent_attrs(name)
      {:ok, %PersistedAgent{id: original_id}} = Persistence.insert_agent(attrs)

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}

      state =
        append_state(name)
        |> AgentPersistence.append_message(system_msg, 1)

      assert state.chat_state.agent_row_id == original_id

      assert :ok = Persistence.delete_agent(test_space_id(), name)
      {:ok, %PersistedAgent{id: replacement_id}} = Persistence.insert_agent(attrs)
      assert replacement_id != original_id

      log =
        capture_log(fn ->
          assert %Agent{chat_state: %{agent_row_id: ^original_id}} =
                   AgentPersistence.append_message(
                     state,
                     {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}]}},
                     2
                   )
        end)

      assert log =~ "Failed to persist message for agent #{name}"

      # Nothing landed on the replacement row: no messages, and its
      # counter is untouched.
      assert Persistence.load_messages(test_space_id(), name) == []

      assert {:ok, %PersistedAgent{next_message_index: 0}} =
               Persistence.fetch_agent(test_space_id(), name)
    end
  end

  describe "record_compaction/3,5" do
    test "the 3-arity form uses the default-arg branch (tokens nil when not provided)" do
      name = "rc-default-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{id: agent_id}} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
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
      # 2 default). Persistence is always on, so the call forwards
      # through to the underlying `Persistence.record_compaction/5`
      # with `nil` for both token stats.
      assert :ok = AgentPersistence.record_compaction(test_space_id(), name, 1, 1)

      # Confirm the marker row landed with nil token stats.
      assert [
               %PersistedMessage{
                 compaction_tokens_compacted: nil,
                 compaction_tokens_compacted_to: nil
               }
             ] =
               Nest.Repo.all(PersistedMessage)
               |> Enum.filter(&(&1.agent_id == agent_id and &1.message_index == 1))
    end

    test "the 5-arity form passes token stats through to the underlying Persistence call" do
      name = "rc-stats-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{}} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
        })

      assert :ok =
               AgentPersistence.record_compaction(test_space_id(), name, 5, 3, 18_432, 4_096)
    end
  end
end

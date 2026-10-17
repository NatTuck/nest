defmodule Nest.Agents.Agent.PersistenceTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Persistence` — the per-agent
  wrapper around `Nest.Persistence` that the Agent's `init/1`
  and `__append_message__/2` paths use.

  The wrapper forwards to the real `Persistence.insert_message/4` /
  `update_next_message_index_by_id/2` calls, addressing the row by
  `{space_id, name}` and checking it against the `agents.id` the session
  was started from.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Vocations

  # The subset of `Agent.t()` `append_message/3` reads: the space, the
  # name (the runtime handle, also used in the log), and the `agents.id`
  # row this session's messages belong to.
  defp append_state(name, agent_row_id) do
    %Agent{
      name: name,
      space_id: test_space_id(),
      chat_state: %Agent.ChatState{agent_row_id: agent_row_id}
    }
  end

  defp local_vocation_id do
    {:ok, %Vocations.Vocation{id: id}} =
      Vocations.upsert_vocation(%{
        name: "Agent Persistence Test Default",
        description: "Default for agent persistence tests",
        system_prompt: "You are a helpful test assistant.",
        tools: ["context"]
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
      # `Persistence.insert_message/4`, the second insert is a
      # silent no-op; the wrapper must not raise.
      name = "dup-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{id: agent_id}} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
        })

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      assert {:ok, _} = Persistence.insert_message(test_space_id(), name, system_msg)

      # The Agent's `init/1` calls `persist_initial_system_message/1`
      # which routes through `AgentPersistence.append_message/3`.
      # The second call (the one that triggered the production
      # crash) must succeed without raising.
      assert :ok = AgentPersistence.append_message(append_state(name, agent_id), system_msg, 1)
    end

    test "bumps next_message_index on a fresh insert" do
      name = "bump-#{System.unique_integer([:positive])}"

      {:ok, %PersistedAgent{id: agent_id}} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
        })

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}
      assert :ok = AgentPersistence.append_message(append_state(name, agent_id), system_msg, 1)

      assert [%PersistedAgent{next_message_index: 1}] =
               Nest.Repo.all(PersistedAgent)
               |> Enum.filter(&(&1.name == name))
    end

    test "drops every write whose name now resolves to a different agent's row" do
      # A row deleted out from under a live process (the space-teardown
      # path) plus a successor taking the same name. `agents.id` is a
      # `bigserial`, so the successor's row is a *different* id: writing
      # by name would put the old session's messages into the successor's
      # transcript — and, for a marker, would move the successor's
      # archived boundary — so every write must be dropped instead.
      name = "reused-#{System.unique_integer([:positive])}"
      attrs = agent_attrs(name)
      {:ok, %PersistedAgent{id: original_id}} = Persistence.insert_agent(attrs)

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      state = append_state(name, original_id)
      assert :ok = AgentPersistence.append_message(state, system_msg, 1)

      # Positive control: the same marker call lands while the row is this
      # session's, so the post-takeover assertions below cannot pass
      # vacuously.
      assert :ok = AgentPersistence.record_compaction(state, 2, 2)

      assert {:ok, %PersistedAgent{last_compaction_index: 2}} =
               Persistence.fetch_agent(test_space_id(), name)

      assert :ok = Persistence.delete_agent(test_space_id(), name)
      {:ok, %PersistedAgent{id: replacement_id}} = Persistence.insert_agent(attrs)
      assert replacement_id != original_id

      marker =
        {:compaction,
         %Compaction{
           index: 2,
           archived_count: 2,
           compaction_count: 1,
           tokens_compacted: 100,
           tokens_compacted_to: 20
         }}

      log =
        capture_log(fn ->
          assert :ok =
                   AgentPersistence.append_message(
                     state,
                     {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}]}},
                     2
                   )

          assert :ok = AgentPersistence.append_message(state, marker, 3)

          # The agent-side marker facade checks the same row.
          assert {:error, :agent_row_reused} =
                   AgentPersistence.record_compaction(state, 4, 4, 100, 20)
        end)

      assert log =~ "Failed to persist message for agent #{name}"
      assert log =~ "Failed to persist compaction for agent #{name}"
      assert log =~ "agent_row_reused"

      # Nothing landed on the successor's row: no messages (marker
      # included), no counter bump, no boundary move.
      assert Persistence.load_messages(test_space_id(), name) == []

      assert {:ok, %PersistedAgent{next_message_index: 0, last_compaction_index: -1}} =
               Persistence.fetch_agent(test_space_id(), name)
    end

    test "bumps the counter on the row that took the message, not on the name" do
      # The takeover can land *between* the guarded INSERT and the counter
      # bump: the insert resolves (and writes to) this session's row, and
      # by the time the counter is bumped the name resolves to a
      # successor. The bump must follow the row the insert returned, or it
      # moves the successor's counter with no message to justify it.
      name = "bump-race-#{System.unique_integer([:positive])}"
      attrs = agent_attrs(name)
      {:ok, %PersistedAgent{id: original_id}} = Persistence.insert_agent(attrs)
      state = append_state(name, original_id)

      # Stand in for the interleaving: the insert reports the row it wrote
      # to, and the name is taken over before `append_message/3` bumps.
      Mimic.stub(Nest.Persistence, :insert_message, fn _space, _name, _message, _opts ->
        :ok = Persistence.delete_agent(test_space_id(), name)
        {:ok, %PersistedAgent{id: replacement_id}} = Persistence.insert_agent(attrs)
        send(self(), {:took_over, replacement_id})
        {:ok, %PersistedMessage{agent_id: original_id}}
      end)

      assert :ok =
               AgentPersistence.append_message(
                 state,
                 {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}},
                 1
               )

      assert_received {:took_over, replacement_id}
      assert replacement_id != original_id

      # The successor's counter is untouched: the bump followed the id the
      # insert returned, and a row that no longer exists is a no-op.
      assert {:ok, %PersistedAgent{next_message_index: 0}} =
               Persistence.fetch_agent(test_space_id(), name)
    end

    test "drops an append from a session that does not know which row it owns" do
      # `agent_row_id: nil` means "this process has no row" (a row-less
      # fixture), not "not resolved yet": the writer must not fall back to
      # writing into whatever row the name happens to resolve to.
      name = "no-row-#{System.unique_integer([:positive])}"
      {:ok, %PersistedAgent{}} = Persistence.insert_agent(agent_attrs(name))
      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}

      log =
        capture_log(fn ->
          assert :ok = AgentPersistence.append_message(append_state(name, nil), system_msg, 1)
        end)

      assert log =~ "Failed to persist message for agent #{name}"

      assert Persistence.load_messages(test_space_id(), name) == []
    end

    test "drops an append for a name with no row at all" do
      # Unchanged behaviour: an unresolvable name is `:agent_not_found`,
      # which the wrapper logs and drops like any other write failure.
      name = "gone-#{System.unique_integer([:positive])}"
      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "x"}]}}

      log =
        capture_log(fn ->
          assert :ok =
                   AgentPersistence.append_message(
                     append_state(name, System.unique_integer([:positive])),
                     system_msg,
                     1
                   )
        end)

      assert log =~ "Failed to persist message for agent #{name}"
      assert log =~ "agent_not_found"
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
      # through to the underlying `Persistence.record_compaction`
      # with `nil` for both token stats.
      assert :ok = AgentPersistence.record_compaction(append_state(name, agent_id), 1, 1)

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

      {:ok, %PersistedAgent{id: agent_id}} =
        Persistence.insert_agent(%{
          space_id: test_space_id(),
          name: name,
          model: %{name: "test-model", provider: "test"},
          vocation_id: local_vocation_id()
        })

      assert :ok =
               AgentPersistence.record_compaction(
                 append_state(name, agent_id),
                 5,
                 3,
                 18_432,
                 4_096
               )
    end
  end
end

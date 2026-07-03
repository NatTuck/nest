defmodule Nest.Agents.AgentCompactionPersistenceTest do
  @moduledoc """
  Tests for the persistence side of the compaction regeneration
  path. After every compaction, `regenerate_for_compaction/2`
  inserts the fresh system message, the encoded-summary user
  message, and the compactor's other output into the `messages`
  table. This file pins that contract:

  - the fresh system message lands at `marker_index + 1`
  - the encoded summary lands at `marker_index + 2` (when
    extracted)
  - the compactor's other output is persisted in order
  - a BEAM restart after compaction loads the post-compaction
    state, not the pre-compaction history (regression for the
    latent gap where the compactor's output was in-memory only)

  This file is `async: false` so the agent's regeneration can
  use the test's sandboxed connection (the agent's process is
  started via `start_supervised!/1` from the test process).
  """
  use Nest.DataCase, async: false

  import Mimic

  import Ecto.Query

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  defp test_vocation_id do
    case Process.get(:nest_compaction_persistence_test_vid) do
      nil ->
        {:ok, %Vocations.Vocation{id: id}} =
          Vocations.upsert_vocation(%{
            name: "Compaction Persistence Test Default",
            description: "Default for compaction persistence tests",
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

        Process.put(:nest_compaction_persistence_test_vid, id)
        id

      id ->
        id
    end
  end

  defp insert_agent_row(name, vocation_id) do
    {:ok, row} =
      Persistence.insert_agent(%{
        name: name,
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    row
  end

  defp compactor_messages_with(summary_text) do
    [
      {:system, %System{index: 1, parts: [%Part.Text{text: summary_text}]}},
      {:user, %User{index: 2, parts: [%Part.Text{text: "Next"}], api_logs: []}},
      {:assistant,
       %Assistant{index: 3, parts: [%Part.Text{text: "Assistant next"}], api_logs: []}}
    ]
  end

  describe "post-compaction persistence" do
    test "fresh system message is in the messages table at marker_index + 1" do
      vocation_id = test_vocation_id()

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      insert_agent_row(agent_id, vocation_id)

      # Pre-seed the agent's chat_state so marker_index is
      # well-defined. The fresh system message should land at
      # next_message_index (= 1).
      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 1}}
      end)

      send(
        pid,
        {:compaction_done, compactor_messages_with("[Summary of earlier conversation]:\n\n..."),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      # Use Repo.all directly to assert on the PersistedMessage
      # rows (not the runtime Message.t() tuples that
      # `load_active_messages/1` returns).
      agent_id_int = Nest.Repo.one!(PersistedAgent, where: [name: agent_id]).id

      rows =
        Nest.Repo.all(
          from(m in PersistedMessage,
            where: m.agent_id == ^agent_id_int and is_nil(m.archived_at),
            order_by: [asc: m.message_index]
          )
        )

      assert length(rows) == 4
      assert hd(rows).role == "system"
      assert hd(rows).message_index == 2

      Agent.terminate(pid)
    end

    test "encoded summary user message is in the messages table at marker_index + 2" do
      vocation_id = test_vocation_id()

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      insert_agent_row(agent_id, vocation_id)

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 1}}
      end)

      send(
        pid,
        {:compaction_done,
         compactor_messages_with("[Summary of earlier conversation]:\n\nkey facts"),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      agent_id_int = Nest.Repo.one!(PersistedAgent, where: [name: agent_id]).id

      rows =
        Nest.Repo.all(
          from(m in PersistedMessage,
            where: m.agent_id == ^agent_id_int and is_nil(m.archived_at),
            order_by: [asc: m.message_index]
          )
        )

      # 4 rows: fresh system, encoded summary (user), compactor's
      # user, compactor's assistant.
      assert length(rows) == 4

      assert [
               %PersistedMessage{role: "system", message_index: 2},
               %PersistedMessage{role: "user", message_index: 3},
               %PersistedMessage{role: "user", message_index: 4},
               %PersistedMessage{role: "assistant", message_index: 5}
             ] = rows

      Agent.terminate(pid)
    end

    test "compactor's other output is in the messages table in index order" do
      vocation_id = test_vocation_id()

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      insert_agent_row(agent_id, vocation_id)

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 1}}
      end)

      send(
        pid,
        {:compaction_done,
         compactor_messages_with("[Summary of earlier conversation]:\n\nkey facts"),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      agent_id_int = Nest.Repo.one!(PersistedAgent, where: [name: agent_id]).id

      rows =
        Nest.Repo.all(
          from(m in PersistedMessage,
            where: m.agent_id == ^agent_id_int and is_nil(m.archived_at),
            order_by: [asc: m.message_index]
          )
        )

      assert Enum.map(rows, & &1.message_index) == [2, 3, 4, 5]
      assert Enum.map(rows, & &1.role) == ["system", "user", "user", "assistant"]

      Agent.terminate(pid)
    end

    test "a BEAM restart after compaction loads the post-compaction state" do
      # The latent gap: the compactor's output was in-memory
      # only, so a BEAM restart re-loaded the pre-compaction
      # history. The regeneration helper persists all
      # post-compaction messages so the post-compaction state
      # is the live state across restarts.
      vocation_id = test_vocation_id()

      {pid, agent_id} =
        start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})

      insert_agent_row(agent_id, vocation_id)

      # Pre-seed the agent's messages so there's something to
      # archive.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: [
                  {:user, %User{index: 0, parts: [%Part.Text{text: "Pre"}], api_logs: []}}
                ],
                next_message_index: 1
            }
        }
      end)

      send(
        pid,
        {:compaction_done,
         compactor_messages_with("[Summary of earlier conversation]:\n\npost-state"),
         {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      # Stop the agent (simulating a BEAM restart — the
      # supervisor's on-demand-load path uses the same code
      # that the restart-after-supervision path uses).
      Agent.terminate(pid)

      {:ok, attrs} = Persistence.build_attrs_for_start(agent_id)
      # 4 preloaded messages: fresh system, encoded summary,
      # compactor's user, compactor's assistant.
      assert length(attrs.preloaded_messages) == 4

      # Position 0 is the fresh system; position 1 is the
      # encoded summary (the compactor's summary text
      # re-encoded as a user message).
      assert {:system, %System{}} = Enum.at(attrs.preloaded_messages, 0)
      assert {:user, %User{parts: [%Part.Text{text: t1}]}} = Enum.at(attrs.preloaded_messages, 1)
      assert t1 =~ "post-state"
    end
  end
end

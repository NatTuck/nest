defmodule Nest.Agents.Agent.MessageAppendStatementsTest do
  @moduledoc """
  Pins the append hot path's DB statement budget.

  `MessageAppender` is the single writer of the live message sequence
  and it runs inside the Agent process, so every statement it issues
  queues behind every other message in that mailbox. The path used to
  issue four statements per appended message: two `agents` SELECTs (one
  resolving `messages.agent_id` for the INSERT, a second one inside the
  `next_message_index` UPDATE), the INSERT, and the UPDATE. The id is
  now resolved once per process and cached on
  `chat_state.agent_row_id`, so the steady state is INSERT + UPDATE.

  Statements are counted from Ecto's `[:nest, :repo, :query]` telemetry
  events rather than from the SQL log: the handler is attached per
  capture and only forwards statements whose params mention this test's
  agent name or row id — both unique — so a concurrent test's statements
  never match.
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence

  @event [:nest, :repo, :query]

  test "resolves the agents.id once, then appends in two statements" do
    name = "append-statements-#{System.unique_integer([:positive])}"
    {:ok, %PersistedAgent{id: agent_id}} = Persistence.insert_agent(agent_attrs(name))

    state = state(name, [system(0)])

    {state, first} =
      capture_statements(name, agent_id, fn ->
        {:ok, _stamped, state} = MessageAppender.append_one(state, user(1))
        state
      end)

    # Unresolved id: the resolution SELECT, the INSERT, the counter UPDATE.
    assert length(first) == 3
    assert Enum.any?(first, &(&1 =~ ~s(FROM "agents")))

    # ...and the id is now cached on the state, so the next append never
    # re-resolves it.
    assert state.chat_state.agent_row_id == agent_id

    {_state, second} =
      capture_statements(name, agent_id, fn ->
        {:ok, _stamped, state} = MessageAppender.append_one(state, assistant(2))
        state
      end)

    assert length(second) == 2
    refute Enum.any?(second, &(&1 =~ ~s(FROM "agents")))
    assert Enum.any?(second, &(&1 =~ ~s(INSERT INTO "messages")))
    assert Enum.any?(second, &(&1 =~ ~s(UPDATE "agents")))
  end

  # Run `fun`, then collect the statements it issued. The telemetry
  # handler runs in this process (the appender's DB work is in-process),
  # so every matching statement is already in the mailbox by the time
  # `fun` returns — a single `Process.info(:messages)` snapshot is exact.
  defp capture_statements(name, agent_id, fun) do
    ref = make_ref()
    test_pid = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      @event,
      fn _event, _measurements, metadata, _config ->
        if name in metadata.params or agent_id in metadata.params do
          send(test_pid, {:statement, ref, metadata.query})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    result = fun.()

    statements =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.flat_map(fn
        {:statement, ^ref, sql} -> [sql]
        _other -> []
      end)

    {result, statements}
  end

  defp state(name, messages) do
    %Agent{
      name: name,
      space_id: test_space_id(),
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      chat_state: %Agent.ChatState{messages: messages, next_message_index: next_index(messages)}
    }
  end

  defp next_index(messages), do: Enum.max(Enum.map(messages, &index/1)) + 1

  defp index({_role, %{index: idx}}), do: idx

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}]}}
  end

  defp user(index) do
    {:user, %User{index: index, parts: [%Part.Text{text: "hi"}]}}
  end

  defp assistant(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "hello"}]}}
  end
end

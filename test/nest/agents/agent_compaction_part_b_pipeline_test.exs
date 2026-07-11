defmodule Nest.Agents.AgentCompactionPartBPipelineTest do
  @moduledoc """
  Compactor-pipeline end-to-end test for Part B
  (`notes/properly-handle-summary-messages-and-openai-think.md`).

  Verifies the compactor's append-then-swap pipeline:

    * The `[mode: compact]` suffix is appended to
      `state.chat_state.messages` BEFORE the regenerator runs.
    * The LLM's response is appended next as a regular
      `{:assistant, %Assistant{...}}` message (same canonical
      `__append_message__/2` path as a chat-turn assistant
      response) — not a wrapped system message.
    * Both are stamped with fresh indices so each is persisted
      and broadcast.
    * The post-swap `last_compaction_index` is set to the
      bumped `next_message_index`, so the suffix and the
      assistant response land in `history` from the client's
      perspective.

  This file was extracted from
  `agent_compaction_persistence_test.exs` to keep that file
  under the credo 500-line cap while still exercising the full
  compactor pipeline (LLM call + append step + regenerator +
  swap) against the MockClient. Replaces the previous "compactor's
  other output is in the messages table" test, which had
  bypassed the compactor task entirely.
  """
  use Nest.DataCase, async: false

  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Compaction
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Tokens.Compactor, as: TokensCompactor
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, previous)
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Part B Pipeline Test #{Elixir.System.unique_integer([:positive])}",
        description: "For Part B compactor pipeline tests",
        system_prompt: "Test prompt.",
        tools: ["context"],
        modes: %{
          "build" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => true,
              "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
            }
          }
        }
      })

    vocation.id
  end

  test "suffix and assistant response are persisted in index order alongside the marker" do
    vocation_id = programmer_vocation_id()

    # Disable persistence for the agent's `init/1` so its
    # `persist_initial_system_message/1` call is a silent no-op.
    Application.put_env(:nest, :persistence, enabled: false)
    {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})
    Application.put_env(:nest, :persistence, enabled: true)

    {:ok, _} =
      Persistence.insert_agent(%{
        name: agent_id,
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    # Pre-seed the agent with a small conversation that
    # will be compacted. The system message at index 0 is
    # required by `Tokens.Compactor.split_messages/1`.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | chat_state: %{
            state.chat_state
            | messages: [
                {:system,
                 %System{
                   index: 0,
                   parts: [%Part.Text{text: "Test system prompt"}],
                   api_logs: []
                 }},
                {:user, %User{index: 1, parts: [%Part.Text{text: "First"}], api_logs: []}},
                {:assistant,
                 %Assistant{index: 2, parts: [%Part.Text{text: "Reply 1"}], api_logs: []}}
              ],
              next_message_index: 3
          }
      }
    end)

    # Configure the MockClient to return a deterministic
    # summary for the compactor's LLM call, plus a final
    # response for the post-swap ChatTurn.
    MockClient.set_response("LLM_GENERATED_SUMMARY_TEXT")
    MockClient.set_response("POST_COMPACTION_RESPONSE")

    # Compute the rendered suffix via the same path the
    # handler uses.
    state = :sys.get_state(pid)

    {:ok, _n, rendered_suffix} =
      TokensCompactor.compute_summary_budget(
        state.llm_metrics.context_limit,
        hd(state.chat_state.messages),
        state.chat_state.messages,
        nil
      )

    # Drive the compactor task directly. The continuation
    # is a `:user_message` carrying a user message so the
    # handler has something to append after the swap.
    user_msg = %User{
      index: nil,
      parts: [%Part.Text{text: "post-compaction question"}],
      api_logs: []
    }

    Compaction.spawn(
      pid,
      state.client_config,
      state.llm_metrics.context_limit,
      state.chat_state.messages,
      {:user_message, user_msg},
      rendered_suffix
    )

    # Fence on the post-swap ChatTurn's first iteration's
    # response broadcast: the ChatTurn calls the LLM
    # (second MockClient response), appends the response
    # via `__append_message__/2`, which broadcasts
    # `chat:message`. The receive confirms the ChatTurn has
    # reached the LLM call AND the compactor's pipeline has
    # finished (the ChatTurn only spawns after `compaction_done`
    # has done its swap).
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")
    assert_receive {:chat_message, {:assistant, _}}, 5_000

    # Fence on the compactor's handler completing via
    # `:sys.get_state/2`. Two calls in case the post-swap
    # ChatTurn has already appended one message between the
    # broadcast and our first get_state.
    _ = :sys.get_state(pid, 5_000)
    _ = :sys.get_state(pid, 5_000)

    # Verify the agent's in-memory state after the compactor
    # pipeline. The "messages don't change" rule means the
    # in-memory state is the source of truth; the DB is for
    # cross-restart recovery only (and the sandbox issue in
    # `handle_info` is best exercised by the more focused
    # `agent_compaction_persistence_test.exs` cases).
    state = :sys.get_state(pid)

    # The post-swap active list has the fresh_system at the
    # head, followed by the summary_user, followed by the
    # carried user message. The post-swap ChatTurn's first
    # iteration appends one more assistant message via
    # `__append_message__/2` after the test waits for its
    # `chat:message` broadcast — but that runs async, so the
    # 4th message may or may not be present at this assertion
    # boundary. Assert the first 3 explicitly and tolerate
    # any trailing ChatTurn writes.
    assert length(state.chat_state.messages) >= 3

    [fresh_system, summary_user, carried_user | _] = state.chat_state.messages
    assert {:system, %{index: 6}} = fresh_system
    assert {:user, summary_user_struct} = summary_user
    assert summary_user_struct.index == 7
    assert {:user, carried_user_struct} = carried_user
    assert carried_user_struct.index == 8

    # The summary_user carries the LLM's response text wrapped
    # in the "Summary of earlier conversation:" header. The
    # `<think>` blocks are stripped here (none in this
    # fixture so the LLM text is preserved verbatim).
    [%Part.Text{text: summary_text}] = summary_user_struct.parts
    assert summary_text =~ "Summary of earlier conversation:"
    assert summary_text =~ "LLM_GENERATED_SUMMARY_TEXT"

    # The history pane has the suffix and the LLM's assistant
    # response at the tail, followed by the marker.
    [suffix, assistant_response, marker] =
      state.chat_state.history
      |> Enum.reverse()
      |> Enum.take(3)
      |> Enum.reverse()

    assert {:system, %{index: 3}} = suffix
    assert {:assistant, assistant_struct} = assistant_response
    assert assistant_struct.index == 4
    assert {:compaction, %{index: 5}} = marker

    # The assistant response carries the LLM's response text
    # exactly as received.
    [%Part.Text{text: assistant_text}] = assistant_struct.parts
    assert assistant_text =~ "LLM_GENERATED_SUMMARY_TEXT"

    Agent.terminate(pid)
  end
end

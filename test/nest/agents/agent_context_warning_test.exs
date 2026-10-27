defmodule Nest.Agents.AgentContextWarningTest do
  @moduledoc """
  Regression coverage for the "context-usage warning fires on every
  user message past 25%" bug.

  The "already announced" set lives on
  `state.live.crossed_thresholds` (per conversation, not per turn);
  the in-process turn reads it directly from the Agent state and
  writes the updated set back. Cleared on successful compaction in
  `Machine.Compaction`. The pure unit tests for
  `ContextReminder.highest_unannounced/3` live in
  `test/nest/agents/agent/turn/context_reminder_test.exs`;
  this module covers the wiring.

  The notices are **off by default** (issue #176) — a space opts in with its
  `context_warnings` setting — so every test that pins a notice starts its agent
  with `context_warnings: true`, and the tests at the end pin the other half: a
  space that has not opted in is told nothing, while compaction and the
  per-tool-result cap carry on unaffected.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    :ok
  end

  # Build a chat turn whose seed messages already cross 25% of the
  # working budget. `context_limit: 10_000` makes the reserve
  # `max(8_192, 2_000) = 8_192` and the working budget 1_808,
  # so 25% fires at ~452 used tokens. The 4_000-char user body
  # tokenizes to ~643 tokens, well past 25%. Small enough to
  # keep the LLM round-trip fast and avoid the Ecto Sandbox
  # ownership timeout (default 30 s).
  defp seed_past_25_percent(pid) do
    :sys.replace_state(
      pid,
      fn state ->
        big_text = String.duplicate("x", 4_000)

        messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "Test system prompt."}],
             api_logs: []
           }},
          {:user, %User{index: 1, parts: [%Part.Text{text: big_text}], api_logs: []}}
        ]

        %{
          state
          | chat_state: %{state.chat_state | messages: messages},
            llm_metrics: %{state.llm_metrics | context_limit: 10_000}
        }
      end,
      1_000
    )
  end

  defp count_reminders(state, text_pattern) do
    Enum.count(state.chat_state.messages, fn
      {:system, %{parts: parts}} ->
        has_text?(parts, text_pattern)

      {:user, %{parts: parts}} ->
        has_text?(parts, text_pattern)

      {:assistant, %{parts: parts}} ->
        has_text?(parts, text_pattern)

      {:tool, %Nest.Messages.Tool{parts: parts}} ->
        has_text?(parts, text_pattern)

      _ ->
        false
    end)
  end

  defp has_text?(parts, text_pattern) do
    Enum.any?(parts, fn
      %Part.Text{text: text} -> String.contains?(text, text_pattern)
      _ -> false
    end)
  end

  defp stamped_notice?({_role, %{metadata: %{"context_threshold" => _}}}), do: true
  defp stamped_notice?(_), do: false

  # A conversation seeded past 75% of the working budget: two ~740-token
  # messages against the 1_808-token budget below. The tail is an assistant, so
  # the delivered user message keeps the transcript alternating.
  defp seed_past_75_percent(pid) do
    :sys.replace_state(
      pid,
      fn state ->
        big = String.duplicate("x", 4_600)

        messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "Test system prompt."}],
             api_logs: []
           }},
          {:user, %User{index: 1, parts: [%Part.Text{text: big}], api_logs: []}},
          {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: big}], api_logs: []}}
        ]

        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: messages,
                next_message_index: 3
            },
            llm_metrics: %{state.llm_metrics | context_limit: 10_000}
        }
      end,
      1_000
    )
  end

  @tag timeout: 2_000
  test "fires :p25 once across multiple user messages past 25%" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{context_warnings: true})

    seed_past_25_percent(pid)

    :ok = Agent.chat(pid, "First message")
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    :ok = Agent.chat(pid, "Second message")
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    :ok = Agent.chat(pid, "Third message")
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    # allowlist: snapshot — messages + context_projection
    state = :sys.get_state(pid, 1_000)

    assert count_reminders(state, "Context at 25%") == 1,
           "expected exactly one :p25 reminder across three user messages, " <>
             "got #{count_reminders(state, "Context at 25%")}"

    # The injected notice is stamped with its threshold so the
    # announced set can be rebuilt after a BEAM restart.
    assert Enum.any?(state.chat_state.messages, &stamped_notice?/1),
           "expected the fired reminder to carry context_threshold metadata"

    # The turn went idle, so any forward-looking projection was cleared.
    assert state.live.context_projection == nil
  end

  test "compaction_done clears crossed_thresholds so the next turn can re-fire" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{context_warnings: true})

    :sys.replace_state(
      pid,
      fn state ->
        # Seeded messages are short enough that any post-compaction
        # turn will be well under 25% of the working budget,
        # so the cleared set stays cleared (no reminder fires).
        messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "System"}],
             api_logs: []
           }},
          {:user, %User{index: 1, parts: [%Part.Text{text: "Hi"}], api_logs: []}}
        ]

        %{
          state
          | chat_state: %{state.chat_state | messages: messages},
            live: %{state.live | crossed_thresholds: MapSet.new([:p25, :p50, :p75])},
            llm_metrics: %{state.llm_metrics | context_limit: 200_000}
        }
      end,
      1_000
    )

    AgentTestHelpers.send_compaction_done(pid, "Summary", nil)

    # The handler resets the set BEFORE starting the next turn.
    # The next turn runs an iteration (against the short seeded
    # messages, well under 25%) and finalizes to :idle. After that
    # the field must still be empty (no reminder fires).
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    crossed = Agent.get_crossed_thresholds(pid, 1_000)

    assert crossed == %MapSet{},
           "expected crossed_thresholds cleared after compaction, " <>
             "got #{inspect(crossed)}"
  end

  describe "a space that has not opted in" do
    @tag timeout: 2_000
    test "crossing 75% appends no notice, and the conversation still compacts" do
      # The setting gates the notices and nothing else (issue #176). This
      # conversation crosses 75% of the working budget, so the delivery of the
      # next message is exactly where a notice would land — and the reply's
      # reported usage then spends the reserve, which is the compaction the
      # flag must not touch.
      {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

      info = Agent.get_public_info(pid, 1_000)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{info.space_id}:#{info.name}")

      seed_past_75_percent(pid)

      # A reply whose reported usage spends the reserve: the carried reply does
      # not fit, so the machine compacts instead of persisting it.
      MockClient.set_stream_events([
        {:text, "FINAL"},
        {:usage, %{input_tokens: 9_000, output_tokens: 10}}
      ])

      :ok = Agent.chat(pid, "keep going")

      assert_receive {:chat_compaction, %{marker: _}}, 2_000
      assert_receive {:chat_status, %{status: "idle"}}, 2_000

      # The compaction really ran: its summary row is in the active transcript.
      messages = Agent.get_messages(pid, 1_000)

      assert Enum.any?(messages, &summary_row?/1),
             "expected the compaction's summary row; got #{inspect(messages)}"

      # No notice was ever appended. The assertion is on the *frames*, not the
      # active transcript: the compaction archived the segment a notice would
      # have landed in, and `crossed_thresholds` is cleared by the commit — so a
      # transcript read here could not tell a gate from a wipe. Both frames below
      # are ordered before the commit's own, so they are in the mailbox by now.
      refute_received {:chat_message, {:user, %User{metadata: %{"context_threshold" => _}}}}

      refute_received {:chat_message,
                       {:assistant, %Assistant{parts: [%Part.Text{text: "Context?"}]}}}
    end

    @tag timeout: 5_000
    test "a tool result is still capped, and nothing is announced" do
      # The cap is `CapCalculator.usable_remaining/1`'s — `L - C - size(messages)`
      # — and reads neither the setting nor the thresholds, so it must bite here
      # exactly as it does for a space that opted in. The seed is past 25%, which
      # is the threshold an ungated notice site would have fired on.
      workspace = AgentTestHelpers.default_test_workspace()
      big_file = Path.join(workspace, "big.txt")
      File.write!(big_file, String.duplicate("x", 60_000))

      {pid, _agent_id} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
          workspace_path: workspace
        })

      seed_past_25_percent(pid)

      MockClient.set_tool_response(%{
        text: "Reading it",
        tool_calls: [
          %{id: "call_1", name: "shell-cmd", arguments: %{"command" => "cat big.txt"}}
        ]
      })

      MockClient.set_response("Done")

      :ok = Agent.chat(pid, "Read the whole file")

      # The batch's own broadcast is the barrier for the real work: the result is
      # appended only after the command has run and the cap has been applied.
      assert_receive {:chat_message, {:tool, %Tool{parts: [part | _]}}}, 4_000
      assert_receive {:chat_status, %{status: "idle"}}, 4_000

      assert %Part.ToolResult{content: content} = part

      # Over the inline budget, so it is the pointer + head substitute, not the
      # whole 60 kB.
      assert content =~ "Command output of 'cat big.txt'"
      assert content =~ "saved to"
      assert String.length(content) < 60_000

      messages = Agent.get_messages(pid, 1_000)

      refute Enum.any?(messages, &stamped_notice?/1),
             "expected no context notice; got #{inspect(messages)}"

      assert Agent.get_crossed_thresholds(pid, 1_000) == %MapSet{}
    end
  end

  # The compaction's summary row: the runtime's header, then the body. The
  # wording matters — a context notice is a runtime user row too, so "the
  # runtime spoke" cannot tell a compaction from a notice.
  defp summary_row?({:user, %User{parts: [%Part.Text{text: text}]}}) when is_binary(text),
    do:
      String.starts_with?(text, "[From nest runtime") and
        text =~ "Summary of previous conversation"

  defp summary_row?(_message), do: false
end

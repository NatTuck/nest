defmodule Nest.Agents.AgentPostToolCallContentTest do
  @moduledoc """
  Post-tool-call thinking + text routing.

  After a tool call, the second LLM turn often emits a
  thinking block before the visible answer (e.g. an LLM
  reasoning about the tool result). The persisted assistant
  message's `content` field must hold the visible text, and
  its `thinking` field must hold the hidden reasoning — the
  two must not be swapped, and the api_log's response
  payload's `content` field must match the visible text.

  This was the root cause of the "after a tool call, the
  LLM response shows just logs but no content" bug:
  `Nest.LLM.StreamConsumer.dispatch/3` was folding
  `{:thinking, _}` events into `acc.text` instead of
  `acc.thinking`, so the chat task's `RunResponse.text`
  (which feeds the api_log's `content` field) was actually
  the model's hidden reasoning, while the user-visible
  assistant message's `content` was empty.
  """
  use Nest.DataCase, async: true

  import Mimic
  import ExUnit.CaptureLog

  # `Agent.chat/2` is a `GenServer.cast`, so a fence placed after it covers the
  # *whole* turn: here a mocked LLM call, a real tool execution and a second
  # mocked LLM call. 500 ms is not a bound for that under load — a whole mocked
  # turn measured p50 18.7 ms / max 34.3 ms across 40 samples in the full
  # suite, but p50 926 ms / max 1534 ms (39 of 40 over 500 ms) under 48 CPU
  # burners. 2000 ms is ~100x the in-suite median and is also the `#21` cap on
  # every test-side timeout, so a genuinely stuck turn still fails — as a stuck
  # turn, not as a flake. (Measured on the spawn turn in `sub_agent_tools_test.exs`;
  # the turns in this file are the same class.)
  @turn_fence_ms 1_000

  alias Nest.Agents.Agent

  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  defp only_text(parts) do
    parts
    |> Enum.filter(&match?(%Part.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp only_thinking(parts) do
    parts
    |> Enum.filter(&match?(%Part.Thinking{}, &1))
    |> Enum.map_join("", & &1.thinking)
  end

  describe "post-tool-call content vs. thinking routing" do
    test "the post-tool assistant message's content and thinking stay in their own fields" do
      # First turn: emit a tool call.
      MockClient.set_stream_events([
        {:text, "Let me check the directory"},
        {:tool_call_start, %{id: "call_1", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 20, total_tokens: 120}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Let me check the directory",
             tool_calls: [%ToolCall{id: "call_1", name: "shell-cmd", arguments: %{}}],
             stop_reason: "tool_calls"
           }
         }}
      ])

      # Second turn: emit a thinking block followed by a
      # visible answer. The model is reasoning about the tool
      # result before responding.
      MockClient.set_stream_events([
        {:thinking, "The directory has a few files. "},
        {:thinking, "Let me summarize them for the user."},
        {:text, "There are 3 files in the directory."},
        {:usage, %{input_tokens: 110, output_tokens: 30, total_tokens: 140}},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: "There are 3 files in the directory.",
             thinking: "The directory has a few files. Let me summarize them for the user.",
             stop_reason: "stop"
           }
         }}
      ])

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "List the files")

          await_idle()

          messages = chat_messages(pid)

          msg1 = assistant_with_tool_use(messages)
          assert msg1 != nil

          assert Enum.any?(msg1.parts, &match?(%Part.ToolUse{}, &1)),
                 "expected first turn assistant to have a Part.ToolUse"

          msg2 = assistant_with_text_and_thinking(messages)
          assert msg2 != nil

          text = only_text(msg2.parts)
          thinking = only_thinking(msg2.parts)
          assert text == "There are 3 files in the directory."
          assert thinking == "The directory has a few files. Let me summarize them for the user."
        end)

      # Empty `arguments: %{}` on the shell_cmd call fails tool
      # validation (`command` required). The BatchSizer diagnostic
      # is the test's incidental side-effect.
      assert log =~ "Missing required arguments: command"

      MockClient.clear()
    end

    # The turn's transcript. `MessageAppender.append_stamped/2` appends and
    # broadcasts each message before the settle loop broadcasts the `idle`
    # status, so after `await_idle/0` the whole turn is readable from the state.
    defp chat_messages(pid), do: Agent.get_messages(pid)

    # The first `{:assistant, msg}` in `messages` satisfying `predicate`; nil
    # when none does.
    defp find_assistant(messages, predicate) do
      Enum.find_value(messages, fn
        {:assistant, msg} ->
          if predicate.(msg), do: msg

        _other ->
          nil
      end)
    end

    # The assistant message whose thinking opens with the expected prefix.
    defp assistant_with_thinking(messages) do
      find_assistant(messages, fn msg ->
        Enum.any?(msg.parts, fn
          %Part.Thinking{thinking: text} ->
            String.starts_with?(text, "The user wants a count.")

          _ ->
            false
        end)
      end)
    end

    # The assistant message that carries a tool call.
    defp assistant_with_tool_use(messages) do
      find_assistant(messages, fn msg ->
        Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))
      end)
    end

    # The post-tool assistant message: visible text and thinking from the same
    # turn, with no tool call of its own.
    defp assistant_with_text_and_thinking(messages) do
      find_assistant(messages, &matches_text_and_thinking?/1)
    end

    defp matches_text_and_thinking?(msg) do
      has_text =
        Enum.any?(msg.parts, fn
          %Part.Text{text: text} -> text == "There are 3 files in the directory."
          _ -> false
        end)

      has_thinking = Enum.any?(msg.parts, &match?(%Part.Thinking{}, &1))
      has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))

      has_text and has_thinking and not has_tool_use
    end

    # The api_logs of the turn's final assistant message: the first assistant
    # message after the tool call (no `Part.ToolUse` of its own) that carries a
    # recorded API log; nil when the turn recorded none.
    defp final_assistant_api_logs(messages) do
      case find_assistant(messages, fn msg ->
             not Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1)) and
               msg.api_logs != nil and msg.api_logs != []
           end) do
        nil -> nil
        msg -> msg.api_logs
      end
    end

    test "the post-tool api_log response payload's content matches the visible text" do
      # The api_log's response payload's `content` field is
      # populated from `RunResponse.text` (see
      # `Broadcasts.api_response_from_run/1`). With the
      # `{:thinking, _}` misrouting bug, that field was the
      # hidden reasoning rather than the visible text.
      MockClient.set_stream_events([
        {:text, "Calling shell"},
        {:tool_call_start, %{id: "call_x", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_x", arguments_delta: "{}"}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling shell",
             tool_calls: [%ToolCall{id: "call_x", name: "shell-cmd", arguments: %{}}],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_stream_events([
        {:thinking, "I need to interpret the result"},
        {:text, "Result: success"},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: "Result: success",
             thinking: "I need to interpret the result",
             stop_reason: "stop"
           }
         }}
      ])

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Run it")

          await_idle()

          logs = final_assistant_api_logs(chat_messages(pid))
          assert logs != nil and logs != []

          response_log = Enum.find(logs, fn log -> log.type == :response end)

          assert response_log,
                 "expected a response log in the post-tool assistant message's api_logs"

          assert response_log.payload.content == "Result: success"
          refute response_log.payload.content =~ "interpret"
        end)

      # `call_x` arguments `{}` fails shell_cmd validation. The
      # diagnostic is incidental; the test's contract is the
      # api_log content.
      assert log =~ "Missing required arguments: command"

      MockClient.clear()
    end

    test "a turn with only thinking events and no visible text has nil content and non-nil thinking" do
      # Models sometimes emit only thinking (no visible text)
      # in a turn — e.g. when reasoning about a tool result
      # and concluding that no reply is needed. The persisted
      # message's `content` must be nil, and `thinking` must
      # hold the reasoning.
      MockClient.set_stream_events([
        {:text, "Calling tool"},
        {:tool_call_start, %{id: "call_only", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_only", arguments_delta: "{}"}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling tool",
             tool_calls: [%ToolCall{id: "call_only", name: "shell-cmd", arguments: %{}}],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_stream_events([
        {:thinking, "The user wants a count. The result has 5 entries."},
        {:thinking, " I'll just summarize."},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: nil,
             thinking: "The user wants a count. The result has 5 entries. I'll just summarize.",
             stop_reason: "stop"
           }
         }}
      ])

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "How many?")

          # The turn's end is the fence: the idle frame is emitted after the
          # turn's last append, so it decides that the transcript is complete.
          await_idle()

          # The context-notice synthetic pair may shift the exact index, so
          # find the assistant by its thinking content.
          thinking_msg = assistant_with_thinking(chat_messages(pid))

          assert thinking_msg != nil
          assert Enum.any?(thinking_msg.parts, &match?(%Part.Thinking{}, &1))

          MockClient.clear()
        end)

      # The empty `arguments: %{}` on the shell_cmd call gets
      # validated by the tool wrapper, which requires `:command`.
      # BatchSizer's permanent diagnostic fires alongside the
      # normal is_error=true result.
      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "tool=shell-cmd"
      assert log =~ "Missing required arguments: command"
    end
  end

  describe "thinking + text + tool_call in one turn" do
    test "the tool-call assistant message preserves thinking from the response" do
      # A single LLM turn emits thinking, visible text, AND a
      # tool call. The persisted assistant message (which is
      # the one broadcast to the UI as `chat:message`) must
      # carry the `thinking` field — otherwise the client-side
      # `addChatMessage` reducer would replace the streaming
      # partial (which has the thinking in `segments`) with a
      # thinking-less final, and the yellow Thinking box would
      # disappear the moment the tool call lands.
      #
      # Regression for the `build_tool_pair/3` omission bug.
      MockClient.set_stream_events([
        {:thinking, "Let me check the directory listing. "},
        {:thinking, "I'll run ls."},
        {:text, "Running ls"},
        {:tool_call_start, %{id: "call_1", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 20, total_tokens: 120}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Running ls",
             thinking: "Let me check the directory listing. I'll run ls.",
             tool_calls: [%ToolCall{id: "call_1", name: "shell-cmd", arguments: %{}}],
             stop_reason: "tool_calls"
           }
         }}
      ])

      # Second turn after the tool result.
      MockClient.set_stream_events([
        {:text, "Done."},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: "Done.",
             stop_reason: "stop"
           }
         }}
      ])

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "List the files")

          await_idle()

          tool_assistant = assistant_with_tool_use(chat_messages(pid))
          assert tool_assistant != nil
          parts = tool_assistant.parts

          assert only_text(parts) == "Running ls"

          assert only_thinking(parts) ==
                   "Let me check the directory listing. I'll run ls."

          assert Enum.any?(parts, &match?(%Part.ToolUse{}, &1))
        end)

      # Same incidental shell_cmd validation failure.
      assert log =~ "Missing required arguments: command"

      MockClient.clear()
    end
  end

  # Wait for the turn to end, on the `chat:status` frame the machine emits when
  # it settles back to `:idle`. `AgentTestHelpers.start_agent/1` subscribes this
  # test pid to the agent's topic, so the frame is the event that decides the
  # turn is over; `@turn_fence_ms` is only the failure bound. Polling
  # `Nest.Agents.Agent.Machine.status_for/1` instead would re-read the state this
  # frame already announced, and would let a broadcast regression pass as
  # success.
  defp await_idle do
    assert_receive {:chat_status, %{status: "idle"}}, @turn_fence_ms
  end
end

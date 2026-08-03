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
        {:tool_call_start, %{id: "call_1", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 20, total_tokens: 120}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Let me check the directory",
             tool_calls: [%ToolCall{id: "call_1", name: "shell_cmd", arguments: %{}}],
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

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "List the files")

      # Fence on idle: 500ms accounts for preflight BPE init
      # (Tiktoken CL100K count_tokens is a DirtyCpu NIF; first
      # call on each of BEAM's 32 dirty CPU threads pays a
      # 200-325ms init cost). Once the fence passes, every
      # earlier chat message has already arrived in the test's
      # mailbox.
      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Wait for the first turn's tool-call assistant message.
      # The synthetic context-notice pair (assistant("Context?")
      # + user(notice)) may precede it when a threshold crosses.
      msg1 = wait_for_assistant_with_tool_use(5_000)
      assert msg1 != nil

      assert Enum.any?(msg1.parts, &match?(%Part.ToolUse{}, &1)),
             "expected first turn assistant to have a Part.ToolUse"

      # Wait for the second turn's assistant message. Its
      # parts must include the visible text and the thinking.
      msg2 = wait_for_assistant_with_text_and_thinking(5_000)
      assert msg2 != nil

      text = only_text(msg2.parts)
      thinking = only_thinking(msg2.parts)
      assert text == "There are 3 files in the directory."
      assert thinking == "The directory has a few files. Let me summarize them for the user."

      MockClient.clear()
    end

    defp wait_for_assistant_with_thinking(wanted_prefix, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout

      do_wait_for_assistant_with_thinking(wanted_prefix, deadline)
    end

    defp do_wait_for_assistant_with_thinking(_prefix, deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        nil
      else
        receive do
          {:chat_message, {:assistant, msg}} ->
            has_thinking =
              Enum.any?(msg.parts, fn
                %Part.Thinking{thinking: text} ->
                  String.starts_with?(text, "The user wants a count.")

                _ ->
                  false
              end)

            if has_thinking do
              msg
            else
              do_wait_for_assistant_with_thinking("The user wants a count.", deadline)
            end
        after
          100 -> do_wait_for_assistant_with_thinking("The user wants a count.", deadline)
        end
      end
    end

    defp wait_for_assistant_with_tool_use(timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout

      do_wait_for_assistant_with_tool_use(deadline)
    end

    defp do_wait_for_assistant_with_tool_use(deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        nil
      else
        receive do
          {:chat_message, {:assistant, msg}} ->
            if Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1)) do
              msg
            else
              do_wait_for_assistant_with_tool_use(deadline)
            end
        after
          100 -> do_wait_for_assistant_with_tool_use(deadline)
        end
      end
    end

    defp wait_for_assistant_with_text_and_thinking(timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout

      do_wait_for_assistant_with_text_and_thinking(deadline)
    end

    defp do_wait_for_assistant_with_text_and_thinking(deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        nil
      else
        receive do
          {:chat_message, {:assistant, msg}} ->
            if matches_text_and_thinking?(msg) do
              msg
            else
              do_wait_for_assistant_with_text_and_thinking(deadline)
            end
        after
          100 -> do_wait_for_assistant_with_text_and_thinking(deadline)
        end
      end
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

    defp wait_for_final_assistant_api_logs(timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout

      do_wait_for_final_assistant_api_logs(deadline)
    end

    defp do_wait_for_final_assistant_api_logs(deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        nil
      else
        receive do
          {:chat_message, {:assistant, msg}} ->
            has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))
            has_api_logs = msg.api_logs != nil and msg.api_logs != []

            cond do
              has_tool_use ->
                do_wait_for_final_assistant_api_logs(deadline)

              not has_api_logs ->
                do_wait_for_final_assistant_api_logs(deadline)

              true ->
                msg.api_logs
            end
        after
          100 -> do_wait_for_final_assistant_api_logs(deadline)
        end
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
        {:tool_call_start, %{id: "call_x", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_x", arguments_delta: "{}"}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling shell",
             tool_calls: [%ToolCall{id: "call_x", name: "shell_cmd", arguments: %{}}],
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

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Run it")

      # The final assistant message carries its api_logs
      # (re-broadcast after the response log lands). Drain to
      # the SECOND assistant (the first carries the tool call;
      # a context-notice synthetic pair may also be present).
      logs = wait_for_final_assistant_api_logs(5_000)
      assert logs != nil and logs != []

      # The response log's `content` field is the visible text,
      # not the thinking. (Before the fix, this assertion
      # would have failed because `Client.accumulate(acc,
      # {:text, text})` was being called for thinking events,
      # folding the reasoning into `acc.text` → `response.text`
      # → the api_log's `content`.)
      response_log = Enum.find(logs, fn log -> log.type == :response end)

      assert response_log,
             "expected a response log in the post-tool assistant message's api_logs"

      assert response_log.payload.content == "Result: success"
      refute response_log.payload.content =~ "interpret"

      assert_receive {:chat_status, %{status: "idle"}}, 500

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
        {:tool_call_start, %{id: "call_only", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_only", arguments_delta: "{}"}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling tool",
             tool_calls: [%ToolCall{id: "call_only", name: "shell_cmd", arguments: %{}}],
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

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "How many?")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Drain to find the assistant with the expected thinking
      # content. The context-notice synthetic pair may shift the
      # exact index, so match by content.
      thinking_msg = wait_for_assistant_with_thinking("The user wants a count.", 5_000)
      assert thinking_msg != nil
      assert Enum.any?(thinking_msg.parts, &match?(%Part.Thinking{}, &1))

      MockClient.clear()
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
        {:tool_call_start, %{id: "call_1", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 20, total_tokens: 120}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Running ls",
             thinking: "Let me check the directory listing. I'll run ls.",
             tool_calls: [%ToolCall{id: "call_1", name: "shell_cmd", arguments: %{}}],
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

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "List the files")

      # The tool-call assistant message carries the thinking
      # part — that's the regression guard. A context-notice
      # synthetic pair may precede this message, so drain to
      # find the one with the tool call.
      tool_assistant = wait_for_assistant_with_tool_use(5_000)
      assert tool_assistant != nil
      parts = tool_assistant.parts

      assert only_text(parts) == "Running ls"

      assert only_thinking(parts) ==
               "Let me check the directory listing. I'll run ls."

      assert Enum.any?(parts, &match?(%Part.ToolUse{}, &1))

      # The agent still goes idle after the post-tool reply.
      assert_receive {:chat_status, %{status: "idle"}}, 500

      MockClient.clear()
    end
  end
end

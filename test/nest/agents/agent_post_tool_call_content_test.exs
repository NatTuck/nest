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
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List the files")

      # Wait for the first turn's tool-call assistant message.
      assert_receive {:chat_message, {:assistant, %{index: 2, tool_calls: [_]}}}, 200

      # Wait for the second turn's assistant message. Its
      # `content` must be the visible text, and its `thinking`
      # must be the model's reasoning.
      assert_receive {:chat_message,
                      {:assistant,
                       %{
                         index: 4,
                         content: "There are 3 files in the directory.",
                         thinking:
                           "The directory has a few files. Let me summarize them for the user."
                       }}},
                     200

      assert_receive {:chat_status, %{status: "idle"}}, 200

      MockClient.clear()
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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run it")

      # The final assistant message carries its api_logs
      # (re-broadcast after the response log lands). Match the
      # version with a non-empty api_logs list.
      assert_receive {:chat_message, {:assistant, %{index: 4, api_logs: [_ | _] = logs}}}, 500

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "How many?")

      # The final assistant message has nil content (no
      # visible text was streamed) and a thinking field with
      # the reasoning.
      assert_receive {:chat_message,
                      {:assistant,
                       %{index: 4, content: nil, thinking: "The user wants a count." <> _}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List the files")

      # The tool-call assistant message carries the thinking
      # field — that's the regression guard.
      assert_receive {:chat_message,
                      {:assistant,
                       %{
                         index: 2,
                         tool_calls: [_],
                         thinking: "Let me check the directory listing. I'll run ls."
                       }}},
                     500

      # The agent still goes idle after the post-tool reply.
      assert_receive {:chat_status, %{status: "idle"}}, 1000

      MockClient.clear()
    end
  end
end

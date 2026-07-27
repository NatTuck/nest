defmodule Nest.TestSupport.AssistantWaiters do
  @moduledoc """
  Test helpers for waiting on specific assistant messages in
  the chat:message broadcast stream.

  When a context-notice synthetic pair is injected before the
  LLM's actual response, a test using `assert_receive` to match
  a specific assistant message will pick up the "Context?"
  attention message instead. These helpers drain the mailbox
  until the desired assistant message arrives.

  Usage:

      msg = AssistantWaiters.assistant_with_tool(pid, "call_123", 5_000)
      assert msg != nil
  """

  alias Nest.Messages.Part

  def assistant_with_tool(pid, tool_call_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assistant_with_tool(pid, tool_call_id, deadline)
  end

  def assistant_with_text(pid, wanted_text, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assistant_with_text(pid, wanted_text, deadline)
  end

  defp do_assistant_with_tool(pid, wanted_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          if Enum.any?(msg.parts, &match?(%Part.ToolUse{id: ^wanted_id}, &1)) do
            msg
          else
            do_assistant_with_tool(pid, wanted_id, deadline)
          end
      after
        100 -> do_assistant_with_tool(pid, wanted_id, deadline)
      end
    end
  end

  defp do_assistant_with_text(pid, wanted, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))

          has_text =
            Enum.any?(msg.parts, fn
              %Part.Text{text: text} -> text == wanted
              _ -> false
            end)

          if has_text and not has_tool_use do
            msg
          else
            do_assistant_with_text(pid, wanted, deadline)
          end
      after
        100 -> do_assistant_with_text(pid, wanted, deadline)
      end
    end
  end
end

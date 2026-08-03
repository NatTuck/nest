defmodule Nest.TestSupport.AgentToolsWaiters do
  @moduledoc """
  Test helpers for `test/nest/agents/agent_tools_test.exs` that
  drain the chat:message mailbox until a specific message
  arrives. Extracted so the test module stays under credo's
  500-line cap.

  Behavior matches the inline defs that lived in
  `agent_tools_test.exs` before the extraction — same
  `receive` / recursive drain pattern, same `:after 100`
  reschedule, same `:after 0` flood-drain for
  `flush_all_messages/0`.
  """
  alias Nest.Messages.Part

  def wait_for_final_assistant(wanted_text, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_final_assistant(wanted_text, deadline)
  end

  def wait_for_tool_with_api_logs(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_tool_with_api_logs(deadline)
  end

  def flush_all_messages do
    receive do
      _ -> flush_all_messages()
    after
      0 -> :ok
    end
  end

  defp do_wait_for_final_assistant(wanted_text, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          if matches_final_assistant?(msg, wanted_text) and has_api_logs?(msg) do
            msg
          else
            do_wait_for_final_assistant(wanted_text, deadline)
          end
      after
        100 -> do_wait_for_final_assistant(wanted_text, deadline)
      end
    end
  end

  defp matches_final_assistant?(msg, wanted_text) do
    has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))

    has_text =
      Enum.any?(msg.parts, fn
        %Part.Text{text: text} -> text == wanted_text
        _ -> false
      end)

    has_text and not has_tool_use
  end

  defp has_api_logs?(msg) do
    msg.api_logs != nil and msg.api_logs != []
  end

  defp do_wait_for_tool_with_api_logs(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:tool, msg}} ->
          if msg.api_logs != nil and msg.api_logs != [] do
            msg
          else
            do_wait_for_tool_with_api_logs(deadline)
          end
      after
        100 -> do_wait_for_tool_with_api_logs(deadline)
      end
    end
  end
end

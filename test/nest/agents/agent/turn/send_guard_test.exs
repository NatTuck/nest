defmodule Nest.Agents.Agent.Turn.SendGuardTest do
  @moduledoc """
  Send guard: `Iteration.dispatch_batch/2` validates the exact message
  list it is about to hand the HTTP worker. An invalid sequence is never
  sent — the turn crashes in-process (`TurnHandler.chat_crashed_state/3`)
  and the Agent's `chat:error` path surfaces the rule and offending ids.
  See `notes/enforce-mesages-seq-invariants.md`.
  """

  use ExUnit.Case, async: true
  alias Nest.Agents.Agent.Machine

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Turn.Iteration
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

  test "refuses an invalid sequence and never spawns the worker" do
    messages = [assistant_tool_use(0, "call_1"), {:user, %User{index: 1, parts: []}}]
    state = build_state(messages)

    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

    {result, log} =
      ExUnit.CaptureLog.with_log(fn -> Iteration.dispatch_batch(state, messages) end)

    assert {:noreply, returned} = result
    assert log =~ "invalid LLM request"

    assert_receive {:chat_error, %{content: content}}
    assert content =~ "tool_pairing"
    assert content =~ "call_1"

    # The turn is finalized in-process: idle with the turn working memory
    # reset, so a subsequent send cannot reuse the invalid state.
    assert Machine.status_for(returned.live.machine) == :idle
    assert is_nil(returned.live.machine.work.ctx)
  end

  defp assistant_tool_use(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{"command" => "x"}}],
       api_logs: []
     }}
  end

  defp build_state(messages) do
    machine = Machine.status_to_machine(%Machine{}, :streaming)

    work = %Agent.Machine.Work{
      ctx: %{
        agent_pid: self(),
        context_limit: 100_000,
        client_config: %Nest.LLM.ClientConfig{},
        tools: [],
        tool_choice: :auto,
        messages: messages
      }
    }

    %Agent{
      name: nil,
      space_id: nil,
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: %{},
        descendant_usage: %{}
      },
      chat_state: %Agent.ChatState{messages: messages, next_message_index: 2},
      live: %Agent.ChatState.Live{machine: %{machine | work: work}}
    }
  end
end

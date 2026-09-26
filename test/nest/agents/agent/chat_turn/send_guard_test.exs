defmodule Nest.Agents.Agent.ChatTurn.SendGuardTest do
  @moduledoc """
  Phase 3 send guard: `Iteration.dispatch_batch/2` validates the exact
  message list it is about to hand the HTTP worker. An invalid
  sequence is never sent — the turn stops and the Agent's crash path
  surfaces the rule and offending ids. See
  `notes/enforce-mesages-seq-invariants.md`.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.Iteration
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

  test "refuses an invalid sequence and never spawns the worker" do
    messages = [assistant_tool_use(0, "call_1"), {:user, %User{index: 1, parts: []}}]
    state = %State{ctx: %{agent_pid: self(), context_limit: 100_000}}

    assert {:stop, :normal, _state} = Iteration.dispatch_batch(state, messages)

    assert_receive {:chat_crashed, %RuntimeError{message: message}, []}
    assert message =~ "wire preflight"
    assert message =~ "tool_pairing"
    assert message =~ "call_1"
  end

  defp assistant_tool_use(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{"command" => "x"}}],
       api_logs: []
     }}
  end
end

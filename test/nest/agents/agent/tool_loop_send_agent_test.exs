defmodule Nest.Agents.Agent.ToolLoopSendAgentTest do
  @moduledoc """
  Unit coverage for the `agents-send` dispatch in `ToolLoop`: the
  delivered/queued acks, argument validation, missing targets, the
  delivery-error surfaces, and the reply-debt clear a successful send
  performs (issue #31 §1.4). Runs the dispatch directly (no live turn).
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.ChildRegistry
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  # `agent_pid` is this test process, so the debt-clear the worker sends to its
  # own agent lands in the test's mailbox. `mode` is the sending agent's mode —
  # the value `requested_mode/3` holds a `set_mode` request to.
  defp ctx do
    %{
      space_id: 1,
      agent_name: "sender",
      agent_pid: self(),
      context_limit: 100_000,
      messages: [],
      tools: [],
      caps: %{},
      mode: "act"
    }
  end

  defp send_call(args) do
    %ToolCall{id: "send-1", name: "agents-send", arguments: args}
  end

  defp run(args, overrides \\ %{}) do
    {results, _log} = run_with_log(args, overrides)
    results
  end

  # The BatchSizer logs an `is_error=true` line for every error result; capture
  # it so the expected diagnostic doesn't reach the console (and so a test that
  # wants to assert on it can).
  defp run_with_log(args, overrides) do
    with_log(fn -> ToolLoop.execute(Map.merge(ctx(), overrides), nil, [send_call(args)]) end)
  end

  defp stub_send(fun) do
    Mimic.stub(Nest.Agents, :send_message, fn _space_id, _from, _name, _msg, _kind, _mode ->
      fun.()
    end)
  end

  # A stub that reports the mode that rode the delivery, for the `set_mode`
  # cases: what the tool asked for is only observable at the call it makes.
  defp capture_send(reply) do
    test_pid = self()

    Mimic.stub(Nest.Agents, :send_message, fn _space, _from, target, content, kind, mode ->
      send(test_pid, {:sent, target, content, kind, mode})
      reply
    end)
  end

  test "reports a successful send and clears the debt to that peer" do
    # intentional: a delivered AND a queued message are both successful sends
    # (the target owns it from here), so both discharge the obligation to that
    # peer. The clear is a message to this worker's own agent, sent *before*
    # the worker's `{:tool_results, …}`, so mailbox order puts it ahead of the
    # response that settles the turn — the idle gate can then never remind for
    # a reply already in flight.
    cases = [
      {{:ok, :delivered}, "Message delivered to bob."},
      {{:ok, :queued}, "Message queued for bob (busy)."}
    ]

    for {result, ack} <- cases do
      stub_send(fn -> result end)

      assert [%ToolResult{name: "agents-send", content: ^ack, is_error: false}] =
               run(%{"name" => "bob", "message" => "hi"})

      # A cast, so the agent handles it in `handle_cast/2` like every other
      # worker result — and it precedes this worker's `{:tool_results, …}`, so
      # mailbox order discharges the debt before the turn settles.
      assert_received {:"$gen_cast", {:reply_sent, "bob"}}
    end
  end

  test "requires both name and message" do
    assert [%ToolResult{content: content, is_error: true}] = run(%{"message" => "hi"})
    assert content =~ "Missing required argument: name"

    assert [%ToolResult{content: content, is_error: true}] = run(%{"name" => "bob"})
    assert content =~ "Missing required argument: message"
  end

  test "reports a missing target and clears nothing" do
    stub_send(fn -> {:error, :not_found} end)

    assert [%ToolResult{content: content, is_error: true}] =
             run(%{"name" => "ghost", "message" => "hi"})

    assert content == "Agent ghost not found in this space."

    # A failed send is not a reply: the debt stands (decision 11).
    refute_received {:"$gen_cast", {:reply_sent, _}}
  end

  test "surfaces delivery errors" do
    stub_send(fn -> {:error, :inbox_full} end)

    assert [%ToolResult{content: full, is_error: true}] =
             run(%{"name" => "bob", "message" => "hi"})

    assert full =~ "inbox is full"

    stub_send(fn -> {:error, {:status, :needs_repair}} end)

    assert [%ToolResult{content: broken, is_error: true}] =
             run(%{"name" => "bob", "message" => "hi"})

    assert broken =~ "needs_repair"

    # Neither failure cleared the debt: nothing reached the target.
    refute_received {:"$gen_cast", {:reply_sent, _}}
  end

  describe "set_mode" do
    test "a plan sender may not raise a descendant's mode, and the refusal is this call's error" do
      # The monotone rule is checked where the sender's mode is known — the tool
      # call's own context — so a refused change is the call's own error result
      # naming why, never a change that quietly does not happen. The target has
      # to be a real descendant for this to be the *monotone* refusal rather
      # than the "not an agent you spawned" one.
      space_id = System.unique_integer([:positive])
      ChildRegistry.register(space_id, "sender", "bob")
      capture_send({:ok, :delivered})

      {results, log} =
        run_with_log(
          %{"name" => "bob", "message" => "hi", "set_mode" => "act"},
          %{space_id: space_id, mode: "plan"}
        )

      assert [%ToolResult{name: "agents-send", is_error: true, content: content}] = results
      assert content =~ "`plan`"
      assert content =~ "`act`"
      assert content =~ "never raised"

      # Nothing was delivered: the change and the message are one delivery, so a
      # refused change refuses the message with it.
      refute_received {:sent, _, _, _, _, _}

      # BatchSizer logs every `is_error` result: expected, so assert on it.
      assert log =~ "BatchSizer produced is_error=true tool result"
    end

    test "an act sender may lower the target's mode, and it rides the delivery" do
      space_id = System.unique_integer([:positive])
      ChildRegistry.register(space_id, "sender", "bob")
      capture_send({:ok, :delivered})

      assert [%ToolResult{name: "agents-send", is_error: false}] =
               run(%{"name" => "bob", "message" => "hi", "set_mode" => "plan"}, %{
                 space_id: space_id
               })

      assert_received {:sent, "bob", "hi", :agent, "plan"}
    end

    test "`mine` is the sender's own mode" do
      # The one-word spelling for "hand this off to someone who may do what I
      # may": no authority check is needed, because the mode is the sender's.
      capture_send({:ok, :queued})

      {results, _log} =
        run_with_log(
          %{"name" => "bob", "message" => "hi", "set_mode" => "mine"},
          %{mode: "plan"}
        )

      assert [%ToolResult{name: "agents-send", is_error: false}] = results
      assert_received {:sent, "bob", "hi", :agent, "plan"}
    end
  end
end

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
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  # `agent_pid` is this test process, so the debt-clear the worker sends to its
  # own agent lands in the test's mailbox.
  defp ctx do
    %{
      space_id: 1,
      agent_name: "sender",
      agent_pid: self(),
      context_limit: 100_000,
      messages: [],
      tools: [],
      caps: %{}
    }
  end

  defp send_call(args) do
    %ToolCall{id: "send-1", name: "agents-send", arguments: args}
  end

  defp run(args) do
    # The BatchSizer logs an `is_error=true` line for every error result;
    # capture it so the expected diagnostic doesn't reach the console.
    {results, _log} =
      with_log(fn -> ToolLoop.execute(ctx(), nil, [send_call(args)]) end)

    results
  end

  defp stub_send(fun) do
    Mimic.stub(Nest.Agents, :send_message, fn _space_id, _from, _name, _msg -> fun.() end)
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
      assert_receive {:"$gen_cast", {:reply_sent, "bob"}}
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
    refute_receive {:"$gen_cast", {:reply_sent, _}}, 50
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
    refute_receive {:"$gen_cast", {:reply_sent, _}}, 50
  end
end

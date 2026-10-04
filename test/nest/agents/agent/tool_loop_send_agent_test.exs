defmodule Nest.Agents.Agent.ToolLoopSendAgentTest do
  @moduledoc """
  Unit coverage for the `agents-send` dispatch in `ToolLoop`: the
  delivered/queued acks, argument validation, missing targets, and the
  delivery-error surfaces. Runs the dispatch directly (no live turn).
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  defp ctx do
    %{
      space_id: 1,
      agent_name: "sender",
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

  test "reports a delivered message" do
    stub_send(fn -> {:ok, :delivered} end)

    assert [%ToolResult{name: "agents-send", content: content, is_error: false}] =
             run(%{"name" => "bob", "message" => "hi"})

    assert content == "Message delivered to bob."
  end

  test "reports a queued message" do
    stub_send(fn -> {:ok, :queued} end)

    assert [%ToolResult{content: content, is_error: false}] =
             run(%{"name" => "bob", "message" => "hi"})

    assert content == "Message queued for bob (busy)."
  end

  test "requires both name and message" do
    assert [%ToolResult{content: content, is_error: true}] = run(%{"message" => "hi"})
    assert content =~ "Missing required argument: name"

    assert [%ToolResult{content: content, is_error: true}] = run(%{"name" => "bob"})
    assert content =~ "Missing required argument: message"
  end

  test "reports a missing target" do
    stub_send(fn -> {:error, :not_found} end)

    assert [%ToolResult{content: content, is_error: true}] =
             run(%{"name" => "ghost", "message" => "hi"})

    assert content == "Agent ghost not found in this space."
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
  end
end

defmodule Nest.Agents.Agent.ToolLoopQueryErrorTest do
  @moduledoc """
  Failure-path coverage for the blocking `agents-query` dispatch in
  `ToolLoop`.

  The wait for a peer's reply is tagged. A timeout, a failed message
  read, and a target that finished its turn without producing any text
  are three distinct `is_error: true` results with different messages.
  None of them may come back as a successful empty (`""`) tool result:
  the model cannot tell `""` apart from "the agent replied with
  nothing", and a silent empty hides the failure entirely.

  The wait is driven deterministically — the idle broadcast is already
  in the mailbox (or, for the timeout case, a `timeout` below one wait
  slice means the deadline has already passed), so no test sleeps.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  # A positive `context_limit` puts the batch through `BatchSizer.cook/2`'s
  # budgeted path, which is where the `is_error=true` diagnostic is logged.
  defp ctx do
    %{
      space_id: 1,
      agent_name: "querier",
      context_limit: 100_000,
      messages: []
    }
  end

  defp run(args) do
    {[%ToolResult{} = result], log} =
      with_log(fn ->
        ToolLoop.execute(ctx(), nil, [
          %ToolCall{id: "query-1", name: "agents-query", arguments: args}
        ])
      end)

    {result, log}
  end

  # Stub the peer's read + chat. `get_messages/2` is called once for the
  # pre-query message count and again after the idle broadcast.
  defp stub_peer(messages) do
    Mimic.stub(Nest.Agents, :get_messages, fn _space_id, _name -> messages end)
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)
  end

  # An assistant message that carries no text parts (here: a refusal).
  defp textless_reply,
    do: {:assistant, %Assistant{index: 5, parts: [%Part.Refusal{refusal: "No."}]}}

  defp text_reply(text), do: {:assistant, %Assistant{index: 5, parts: [%Part.Text{text: text}]}}

  test "a wait that times out is an error naming the target and the wait" do
    stub_peer({:ok, []})

    {result, log} = run(%{"name" => "peer", "prompt" => "hi", "timeout" => 1})

    assert result.is_error == true
    assert result.name == "agents-query"

    assert result.content ==
             "Could not query peer: timed out after 1ms waiting for its turn to finish."

    assert log =~ "agents-query: target did not go idle within 1ms"
    assert log =~ "BatchSizer produced is_error=true tool result"
  end

  test "a reply with no text is an error, distinct from the timeout" do
    stub_peer({:ok, [textless_reply()]})
    send(self(), {:chat_status, %{status: "idle"}})

    {result, log} = run(%{"name" => "peer", "prompt" => "hi", "timeout" => 250})

    assert result.is_error == true

    assert result.content ==
             "Could not query peer: it finished its turn without producing any text."

    refute result.content =~ "timed out"
    assert log =~ "BatchSizer produced is_error=true tool result"
  end

  test "a reply with text comes back inline as a successful result" do
    stub_peer({:ok, [text_reply("pong")]})
    send(self(), {:chat_status, %{status: "idle"}})

    {result, _log} = run(%{"name" => "peer", "prompt" => "hi", "timeout" => 250})

    assert %ToolResult{is_error: false, content: "pong"} = result
  end

  test "a message read that fails mid-wait is an error, not a timeout" do
    reads = :counters.new(1, [])

    Mimic.stub(Nest.Agents, :get_messages, fn _space_id, _name ->
      :counters.add(reads, 1, 1)

      if :counters.get(reads, 1) == 1 do
        {:ok, []}
      else
        {:error, :not_found}
      end
    end)

    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)
    send(self(), {:chat_status, %{status: "idle"}})

    {result, log} = run(%{"name" => "peer", "prompt" => "hi", "timeout" => 250})

    assert result.is_error == true
    assert result.content == "Could not query peer: could not read its messages: :not_found"
    assert log =~ "BatchSizer produced is_error=true tool result"
  end

  # The wait is bounded by elapsed time, not by how many messages land in
  # the caller's mailbox. The target's own streaming traffic is broadcast
  # on the same topic we subscribed to, so counting messages let a chatty
  # target exhaust the old `div(timeout, @wait_slice_ms)` attempt budget
  # in seconds and report a bogus timeout long before the reply arrived.
  test "unrelated messages on the target's topic do not consume the wait budget" do
    stub_peer({:ok, [text_reply("pong")]})

    # More messages than the old budget (`div(30_000, 250)` == 120), so the
    # attempt-counting wait gave up before it ever reached the idle
    # broadcast. The reply is already in the mailbox, so this completes
    # immediately and never waits out the (generous) timeout.
    flood_unrelated_messages(200)
    send(self(), {:chat_status, %{status: "idle"}})

    {result, _log} = run(%{"name" => "peer", "prompt" => "hi", "timeout" => 30_000})

    assert %ToolResult{is_error: false, content: "pong"} = result
  end

  # A flooded mailbox must not extend (or otherwise perturb) the deadline:
  # with no idle broadcast the wait still ends as a timeout, and promptly.
  test "a flooded mailbox still expires on the deadline" do
    stub_peer({:ok, []})

    flood_unrelated_messages(200)

    {result, log} = run(%{"name" => "peer", "prompt" => "hi", "timeout" => 1})

    assert result.is_error == true

    assert result.content ==
             "Could not query peer: timed out after 1ms waiting for its turn to finish."

    assert log =~ "agents-query: target did not go idle within 1ms"
  end

  # Streaming traffic shapes, as broadcast on the target's topic.
  defp flood_unrelated_messages(count) do
    for n <- 1..count do
      send(self(), {:chat_delta, %{agent: "peer", index: n, text: "..."}})
      send(self(), {:chat_message, %{agent: "peer", index: n}})
    end
  end
end

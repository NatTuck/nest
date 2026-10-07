defmodule Nest.Agents.Agent.WaitLoopTest do
  @moduledoc """
  Coverage for the `agents-wait` dispatch in `ToolLoop` /
  `Nest.Agents.Agent.WaitLoop`.

  The three result paths the tool must have:

    * every target already idle → immediate return;
    * a busy target going idle → that agent's name and its stop message;
    * the wall-clock timeout → a normal (`is_error: false`) result.

  Plus the two target-resolution rules: `[]` means every other agent in
  the space (never the caller), and a name that resolves to no agent is
  an error rather than a silent idle.

  The wait is driven deterministically: the idle status broadcast is
  already in the mailbox (or, for the timeout, a `timeout` below one
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

  defp ctx do
    %{space_id: 1, agent_name: "caller", context_limit: 100_000, messages: []}
  end

  defp run(args) do
    with_log(fn ->
      [%ToolResult{} = result] =
        ToolLoop.execute(ctx(), nil, [
          %ToolCall{id: "wait-1", name: "agents-wait", arguments: args}
        ])

      result
    end)
  end

  # Drive `Nest.Agents.get_info/2` from a per-name FIFO: each read pops
  # the next status, and the last status sticks once the list is
  # exhausted. Per-name queues keep the initial read and every recheck
  # deterministic regardless of the order the targets are visited in.
  # A `:not_found` entry drives the "no live process, no persisted row"
  # read.
  defp stub_statuses(by_name) do
    {:ok, queue} = Agent.start_link(fn -> by_name end)

    Mimic.stub(Nest.Agents, :get_info, fn _space_id, name ->
      Agent.get_and_update(queue, &next_status(&1, name))
    end)
  end

  defp next_status(names, name) do
    case Map.get(names, name, [:idle]) do
      [status] -> {status_reply(status), names}
      [status | rest] -> {status_reply(status), Map.put(names, name, rest)}
    end
  end

  defp status_reply(:not_found), do: {:error, :not_found}
  defp status_reply(status), do: {:ok, %{status: status}}

  defp stub_messages(fun), do: Mimic.stub(Nest.Agents, :get_messages, fun)

  test "returns immediately when every target is already idle" do
    stub_statuses(%{"bob" => [:idle], "carol" => [:idle]})

    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      [
        %{name: "caller", status: :idle},
        %{name: "bob", status: :idle},
        %{name: "carol", status: :idle}
      ]
    end)

    {named, _log} = run(%{"names" => ["bob", "carol"]})

    assert %ToolResult{name: "agents-wait", is_error: false, content: content} = named
    assert content == "All agents are already idle: bob, carol."

    # An empty list means every other agent in the space (the same set
    # `agents-list` reports). The caller is excluded: it is busy running
    # this very call.
    {all, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = all
    assert content == "All agents are already idle: bob, carol."

    # The caller is never a target, however it is named.
    {self_named, _log} = run(%{"names" => ["caller", "bob"]})

    assert %ToolResult{is_error: false, content: content} = self_named
    assert content == "All agents are already idle: bob."
  end

  test "an empty list with no other agents returns immediately" do
    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      [%{name: "caller", status: :idle}]
    end)

    {result, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = result
    assert content == "No other agents in this space to wait for."
  end

  test "a busy target leaving the busy set is reported with its stop message" do
    stub_statuses(%{"bob" => [:streaming, :idle], "carol" => [:streaming]})

    stub_messages(fn _space_id, "bob" ->
      {:ok, [{:assistant, %Assistant{index: 3, parts: [%Part.Text{text: "bob's result"}]}}]}
    end)

    send(self(), {:chat_status, %{status: "idle"}})
    {with_text, _log} = run(%{"names" => ["bob", "carol"]})

    assert %ToolResult{
             is_error: false,
             content: "Agent bob is idle. Final message:\nbob's result"
           } =
             with_text

    # A target that ends its turn without text says so explicitly; it is
    # never a successful empty result.
    stub_statuses(%{"bob" => [:streaming, :idle]})

    stub_messages(fn _space_id, "bob" ->
      {:ok, [{:assistant, %Assistant{index: 3, parts: [%Part.Refusal{refusal: "no"}]}}]}
    end)

    send(self(), {:chat_status, %{status: "idle"}})
    {no_text, _log} = run(%{"names" => ["bob"]})

    assert %ToolResult{is_error: false, content: content} = no_text
    assert content == "Agent bob is idle, but its turn produced no text message."

    # A target that vanishes mid-wait is reported as gone rather than
    # waited out to the timeout.
    stub_statuses(%{"bob" => [:streaming, :not_found]})

    send(self(), {:chat_status, %{status: "idle"}})
    {gone, _log} = run(%{"names" => ["bob"]})

    assert %ToolResult{is_error: false, content: content} = gone
    assert content == "Agent bob is no longer running in this space."
  end

  test "reaching the timeout is a normal result, not an error" do
    stub_statuses(%{"bob" => [:streaming]})

    {result, log} = run(%{"names" => ["bob"], "timeout" => 1})

    assert %ToolResult{name: "agents-wait", is_error: false, content: content} = result
    assert content == "No agent went idle within 1ms. Still busy: bob."
    assert log =~ "agents-wait: no target went idle within 1ms"
  end

  test "an unknown target name is an error, not a silent idle" do
    Mimic.stub(Nest.Agents, :get_info, fn
      _space_id, "bob" -> {:ok, %{status: :idle}}
      _space_id, "ghost" -> {:error, :not_found}
    end)

    {result, log} = run(%{"names" => ["bob", "ghost"]})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = result
    assert content == "Agent ghost not found in this space."
    assert log =~ "BatchSizer produced is_error=true tool result"
  end
end

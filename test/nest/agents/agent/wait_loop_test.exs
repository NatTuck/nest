defmodule Nest.Agents.Agent.WaitLoopTest do
  @moduledoc """
  Coverage for the `agents-wait` dispatch in `ToolLoop` /
  `Nest.Agents.Agent.WaitLoop`.

  The result paths the tool must have:

    * every target already idle → immediate return;
    * a busy target going idle → that agent's name and its stop message;
    * the wall-clock timeout → a normal (`is_error: false`) result.

  Plus the target-resolution rules: `[]` means every other agent in the
  space (never the caller), a name that resolves to no agent is an error
  rather than a silent idle, a read-only wait never starts an agent, and a
  malformed `names`/`timeout` argument is rejected loudly.

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

  # Drive `Nest.Agents.list_agents_info_for_space/1` from a FIFO of space
  # snapshots: each read pops the next snapshot, and the last one sticks
  # once the list is exhausted. One read answers the initial status
  # question and every slice recheck, so a frame can flip a target from
  # busy to idle (or drop it from the space entirely). This is the only
  # status source the wait reads — `Nest.Agents.get_info/2` is never
  # called, which is what keeps the wait read-only.
  defp stub_listing(frames) do
    id = {:wait_listing, System.unique_integer([:positive])}
    queue = start_supervised!({Agent, fn -> frames end}, id: id)

    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      Agent.get_and_update(queue, &next_listing/1)
    end)
  end

  defp next_listing([last]), do: {last, [last]}
  defp next_listing([head | rest]), do: {head, rest}

  defp agent(name, status), do: %{name: name, status: status}

  defp stub_messages(fun), do: Mimic.stub(Nest.Agents, :get_messages, fun)

  # `stop_message/2` reads the target's messages only when it is live, so a
  # persisted-only target is never started. Stub liveness for the tests that
  # report a stop message.
  defp stub_live(names) do
    Mimic.copy(Nest.Agents.Registry)

    Mimic.stub(Nest.Agents.Registry, :lookup, fn _space_id, name ->
      if name in names, do: {:ok, self()}, else: {:error, :not_found}
    end)
  end

  test "returns immediately when every target is already idle" do
    stub_listing([[agent("caller", :idle), agent("bob", :idle), agent("carol", :idle)]])

    {named, _log} = run(%{"names" => ["bob", "carol"]})

    assert %ToolResult{name: "agents-wait", is_error: false, content: content} = named
    assert content == "All agents are already idle: bob, carol."

    # An empty list means every other agent in the space (the same set
    # `agents-list` reports). The caller is excluded: it is busy running
    # this very call.
    {all, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = all
    assert content == "All agents are already idle: bob, carol."

    # An explicit empty list behaves exactly like omitting `names`.
    {explicit, _log} = run(%{"names" => []})

    assert %ToolResult{is_error: false, content: content} = explicit
    assert content == "All agents are already idle: bob, carol."

    # The caller is never a target, however it is named.
    {self_named, _log} = run(%{"names" => ["caller", "bob"]})

    assert %ToolResult{is_error: false, content: content} = self_named
    assert content == "All agents are already idle: bob."

    # An empty space (only the caller) has nothing to wait for and returns
    # immediately rather than erroring.
    stub_listing([[agent("caller", :idle)]])
    {empty, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = empty
    assert content == "No other agents in this space to wait for."
  end

  test "a busy target leaving the busy set is reported with its stop message" do
    stub_live(["bob"])

    stub_listing([
      [agent("bob", :streaming), agent("carol", :streaming)],
      [agent("bob", :idle), agent("carol", :streaming)]
    ])

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
    stub_listing([[agent("bob", :streaming)], [agent("bob", :idle)]])

    stub_messages(fn _space_id, "bob" ->
      {:ok, [{:assistant, %Assistant{index: 3, parts: [%Part.Refusal{refusal: "no"}]}}]}
    end)

    send(self(), {:chat_status, %{status: "idle"}})
    {no_text, _log} = run(%{"names" => ["bob"]})

    assert %ToolResult{is_error: false, content: content} = no_text
    assert content == "Agent bob is idle, but its turn produced no text message."

    # A target that vanishes mid-wait (no live process, no persisted row)
    # is reported as gone rather than waited out to the timeout.
    stub_listing([[agent("bob", :streaming)], []])

    send(self(), {:chat_status, %{status: "idle"}})
    {gone, _log} = run(%{"names" => ["bob"]})

    assert %ToolResult{is_error: false, content: content} = gone
    assert content == "Agent bob is no longer running in this space."
  end

  test "reaching the timeout is a normal result, not an error" do
    stub_listing([[agent("bob", :streaming)]])

    {result, log} = run(%{"names" => ["bob"], "timeout" => 1})

    assert %ToolResult{name: "agents-wait", is_error: false, content: content} = result
    assert content == "No agent went idle within 1ms. Still busy: bob."
    assert log =~ "agents-wait: no target went idle within 1ms"
  end

  test "an unknown target name is an error, not a silent idle" do
    stub_listing([[agent("bob", :idle)]])

    {result, log} = run(%{"names" => ["bob", "ghost"]})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = result
    assert content == "Agent ghost not found in this space."
    assert log =~ "BatchSizer produced is_error=true tool result"
  end

  # `Nest.Agents.get_info/2` on-demand-loads a persisted-only agent, so a
  # wait that read statuses through it would start the very agent it is
  # only observing. The listing reports a persisted-only agent as `:idle`
  # without starting it, and both resolution paths use it — so the same
  # agent gets the same disposition however it is named.
  test "a named persisted-only agent is already idle and is never started" do
    Mimic.reject(Nest.Agents, :get_info, 2)

    stub_listing([[agent("caller", :idle), agent("db-only", :idle)]])

    {named, _log} = run(%{"names" => ["db-only"]})

    assert %ToolResult{is_error: false, content: content} = named
    assert content == "All agents are already idle: db-only."

    {all, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = all
    assert content == "All agents are already idle: db-only."
  end

  # The schema declares `names` as an array of strings. A bare string, or a
  # list with a non-string element, is a model typo, and silently filtering
  # it would mean "every other agent in the space" — a wait on unrelated
  # agents. Fail loudly instead.
  test "a malformed `names` argument is an error, not an implicit empty list" do
    {not_a_list, log} = run(%{"names" => "bob"})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = not_a_list

    assert content ==
             ~s(Invalid `names` argument: expected a list of agent names, got: "bob".)

    assert log =~ "BatchSizer produced is_error=true tool result"

    {bad_element, _log} = run(%{"names" => ["bob", 5]})

    assert %ToolResult{is_error: true, content: content} = bad_element

    assert content ==
             ~s(Invalid `names` argument: expected a list of agent names, got: ["bob", 5].)
  end

  # A non-positive timeout would render "No agent went idle within -1ms";
  # reject it instead.
  test "a non-positive timeout is an error, not a wait with a negative budget" do
    {result, log} = run(%{"names" => ["bob"], "timeout" => -1})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = result

    assert content ==
             "Invalid `timeout` argument: expected a positive integer of milliseconds, " <>
               "got: -1."

    assert log =~ "BatchSizer produced is_error=true tool result"
  end
end

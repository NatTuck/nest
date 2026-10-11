defmodule Nest.Agents.AgentTurnTestHelpers do
  @moduledoc """
  Helpers for turn-level integration tests that drive a real agent and
  inspect its `chat:status` stream and the LLM requests its turn made
  (`Nest.Agents.Agent.TurnAcceptanceTest`'s split files,
  `Nest.Agents.Agent.CloneAgentFlowTest`, `TimelineEmittersTest`,
  `ReplyDebtTest`).

  `statuses_until_idle/1` is an *ordered* collector, not a drain: it stops
  at the first `idle`, so a test can assert the whole sequence and an `idle`
  anywhere before the end fails. `assert_request/0` reads the request lists
  the caller's `MockClient` spy sent.

  `park_llm_requests/1` + `next_request/0` + `release_llm/1` are the
  *parked* variant of the same observation: each request is held until the
  test releases it, so a test that has to read the agent's state (or the
  transcript) at a specific point of a turn is not racing the HTTP worker
  for the agent's mailbox.

  Both fences are 500 ms, the project's cap for test fences: a turn here is
  two mock HTTP calls plus one in-memory tool batch.
  """

  import ExUnit.Assertions

  alias Nest.Agents.AgentTestAssertions
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  # Collect the `chat:status` sequence up to (and including) the first
  # `idle`. `start_agent/1` subscribes the test pid to the agent's topic.
  @spec statuses_until_idle([String.t()]) :: [String.t()]
  def statuses_until_idle(acc \\ []) do
    receive do
      {:chat_status, %{status: "idle"}} ->
        Enum.reverse(["idle" | acc])

      {:chat_status, %{status: status}} ->
        statuses_until_idle([status | acc])
    after
      500 ->
        flunk("no idle status within 500ms; statuses so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  @doc "The next recorded LLM request's message list."
  @spec assert_request() :: [term()]
  def assert_request do
    receive do
      {:llm_request, messages} -> messages
    after
      500 -> flunk("expected another LLM request")
    end
  end

  @doc "The text of every `{:user, _}` message in a message list."
  @spec user_texts([term()]) :: [String.t()]
  def user_texts(messages) do
    for {:user, %{parts: parts}} <- messages, do: AgentTestAssertions.text_from_parts(parts)
  end

  @doc """
  Park every LLM request until the test releases it.

  A turn is otherwise a race between the tool worker and the HTTP worker for
  the agent's mailbox, so the transcript and the status sequence at each step
  are not reproducible. `next_request/0` reads each parked request (the agent
  is blocked in it until `release_llm/1`), so the test decides exactly when the
  turn advances. `pid` is the agent whose `MockClient` queue is stubbed.
  """
  @spec park_llm_requests(pid()) :: :ok
  def park_llm_requests(pid) do
    test_pid = self()

    Mimic.stub(MockClient, :run, fn request, opts ->
      send(test_pid, {:llm_request, request.messages, self()})

      receive do
        :release_llm -> :ok
      after
        # Safety valve only: it exists so a failing test cannot leave the HTTP
        # worker (and with it the turn) parked for long.
        1_000 -> :ok
      end

      Mimic.call_original(MockClient, :run, [request, opts])
    end)

    Mimic.allow(MockClient, self(), pid)
  end

  @doc """
  The next parked request, as `{messages, worker}`. Nothing runs until the
  caller releases `worker`, so it can assert on the state the request was made
  from.
  """
  @spec next_request() :: {[term()], pid()}
  def next_request do
    assert_receive {:llm_request, messages, worker}, 500
    {messages, worker}
  end

  @doc "Release the parked request `worker`."
  @spec release_llm(pid()) :: :ok
  def release_llm(worker), do: send(worker, :release_llm)

  @doc """
  Park the tool worker inside `Nest.Agents.send_message/4` — the `agents-send`
  entry point — so the test decides when the batch's call reaches its target.

  The worker always parks *before* the real delivery: it sends
  `{:send_blocked, worker}` and waits for `:release_send`. With
  `hold_result: true` it parks a second time *after* it, sending
  `{:send_delivered, worker}` and waiting for `:release_result` — so the batch is
  still in flight while the delivered message's turn runs, which is the shape
  where the batch's own result arrives only once that turn has ended. Each
  `after` is a safety valve so a failing test cannot leave the worker parked for
  long.
  """
  @spec park_agent_sends(pid(), keyword()) :: :ok
  def park_agent_sends(pid, opts \\ []) do
    test_pid = self()
    hold_result? = Keyword.get(opts, :hold_result, false)

    Mimic.stub(Nest.Agents, :send_message, fn space_id, from, target, content ->
      park(test_pid, :send_blocked, :release_send)

      result = Mimic.call_original(Nest.Agents, :send_message, [space_id, from, target, content])

      if hold_result?, do: park(test_pid, :send_delivered, :release_result)

      result
    end)

    Mimic.allow(Nest.Agents, self(), pid)
  end

  defp park(test_pid, blocked, release) do
    send(test_pid, {blocked, self()})

    receive do
      ^release -> :ok
    after
      1_000 -> :ok
    end
  end

  @doc "The text of a message's parts (\"\" for a message without parts)."
  @spec text_of(term()) :: String.t()
  def text_of({_tag, %{parts: parts}}), do: AgentTestAssertions.text_from_parts(parts)
  def text_of(_message), do: ""

  @doc "The `content` of every tool result in a `{:tool, _}` message."
  @spec tool_texts(term()) :: [String.t()]
  def tool_texts({:tool, %{parts: parts}}) do
    for %Part.ToolResult{content: content} <- parts || [], do: content || ""
  end

  def tool_texts(_message), do: []
end

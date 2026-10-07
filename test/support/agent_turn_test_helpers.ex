defmodule Nest.Agents.AgentTurnTestHelpers do
  @moduledoc """
  Helpers for turn-level integration tests that drive a real agent and
  inspect its `chat:status` stream and the LLM requests its turn made
  (`Nest.Agents.Agent.TurnAcceptanceTest` and any split file).

  `statuses_until_idle/1` is an *ordered* collector, not a drain: it stops
  at the first `idle`, so a test can assert the whole sequence and an `idle`
  anywhere before the end fails. `assert_request/0` reads the request lists
  the caller's `MockClient` spy sent.

  Both fences are 500 ms, the project's cap for test fences: a turn here is
  two mock HTTP calls plus one in-memory tool batch, and the file they serve
  (`TurnAcceptanceTest`) is stable at 500 ms under `mix test … --repeat 20`.
  """

  import ExUnit.Assertions

  alias Nest.Agents.AgentTestAssertions
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

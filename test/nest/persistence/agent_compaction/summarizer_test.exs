defmodule Nest.Persistence.AgentCompaction.SummarizerTest do
  @moduledoc """
  Unit tests for the bounded iterative summarizer, using an injected
  `llm_call` so no HTTP is involved.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence.AgentCompaction.Planner
  alias Nest.Persistence.AgentCompaction.Summarizer
  alias Nest.Tokens.Estimator

  defmodule FailingClient do
    @moduledoc false
    def run(_request, _opts), do: {:error, :transport_error}
  end

  test "folds chunks, passing the running summary into later calls" do
    chunks = [[user_msg(1, "a")], [user_msg(2, "b")]]
    counter = :counters.new(1, [])
    parent = self()

    call = fn messages ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(parent, {:call, n, messages})
      {:ok, "summary-#{n}"}
    end

    assert {:ok, summary} = Summarizer.summarize(plan(chunks, budget: 100_000), call)
    assert summary == "summary-2"

    assert_received {:call, 1, first}
    assert_received {:call, 2, second}
    assert system_text(first) =~ "Summarize the conversation that follows"
    refute system_text(first) =~ "running summary of the earlier conversation"
    assert system_text(second) =~ "summary-1"
  end

  test "includes operator focus in the instruction" do
    chunks = [[user_msg(1, "a")]]

    call = fn messages ->
      send(self(), {:system, system_text(messages)})
      {:ok, "s"}
    end

    assert {:ok, "s"} =
             Summarizer.summarize(plan(chunks, budget: 100_000, focus: "keep API X"), call)

    assert_received {:system, text}
    assert text =~ "keep API X"
  end

  test "rejects an empty summary" do
    call = fn _messages -> {:ok, "   "} end

    assert {:error, :llm_returned_empty} =
             Summarizer.summarize(plan([[user_msg(1, "a")]], budget: 100_000), call)
  end

  test "compresses a summary that overshoots the budget" do
    long = String.duplicate("y", 4_000)
    counter = :counters.new(1, [])
    parent = self()

    call = fn messages ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          {:ok, long}

        n ->
          send(parent, {:compress_call, n, messages})
          {:ok, "short"}
      end
    end

    assert {:ok, "short"} = Summarizer.summarize(plan([[user_msg(1, "a")]], budget: 100), call)
    assert Estimator.estimate(long) > 100
    assert_received {:compress_call, 2, messages}
    assert compress_text(messages) =~ "Compress the following summary"
  end

  test "propagates llm errors" do
    call = fn _messages -> {:error, :boom} end

    assert {:error, :boom} =
             Summarizer.summarize(plan([[user_msg(1, "a")]], budget: 100_000), call)
  end

  test "production llm_call streams a summary through the client" do
    MockClient.start_link()
    MockClient.clear()
    MockClient.set_response("mocked summary")

    config = %ClientConfig{
      client: MockClient,
      base_url: "http://test",
      api_key: "k",
      model: "m",
      receive_timeout: 1_000
    }

    assert {:ok, "mocked summary"} = Summarizer.llm_call(config).([user_msg(1, "a")])
  end

  test "production llm_call surfaces client-level errors" do
    config = %ClientConfig{
      client: FailingClient,
      base_url: "http://test",
      api_key: "k",
      model: "m",
      receive_timeout: 1_000
    }

    assert {:error, :transport_error} = Summarizer.llm_call(config).([user_msg(1, "a")])
  end

  # ---- helpers ----

  defp plan(chunks, opts) do
    %Planner{
      system_text: Keyword.get(opts, :system, "system"),
      summary_budget: Keyword.fetch!(opts, :budget),
      chunks: chunks,
      focus: Keyword.get(opts, :focus)
    }
  end

  defp user_msg(index, text) do
    {:user, %User{index: index, parts: [%Part.Text{text: text}]}}
  end

  defp system_text([{:system, %MsgSystem{parts: [%Part.Text{text: text}]}} | _]), do: text

  defp compress_text([_system, {:user, %User{parts: [%Part.Text{text: text}]}}]), do: text
end

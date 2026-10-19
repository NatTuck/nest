defmodule Nest.LLM.StreamConsumerTest do
  @moduledoc """
  Tests for the shared canonical-event-stream reducer.

  The reducer routes each event type into a different slot on
  the `Client.accumulator()`:

    * `{:text, _}`         → `acc.text`
    * `{:thinking, _}`     → `acc.thinking`
    * `{:thinking_signature, _}` → `acc.thinking_signature`

  Two regressions previously lived in this dispatcher:

    1. `{:thinking, _}` was being folded into `acc.text` (the
       wrong clause of `Client.accumulate/2` was being
       called). The symptom was that the chat task's
       `RunResponse.text` (which feeds the api_log's
       `content` field) was actually the model's hidden
       reasoning, while the user-visible assistant message's
       `content` was empty.

    2. `{:thinking_signature, _}` was being folded into
       `acc.thinking`, concatenating the signature blob into
       the thinking text whenever Anthropic's extended
       thinking emitted one.

  These tests pin the routing so neither can regress.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.Client
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer

  defp build_consumer(opts \\ []) do
    %StreamConsumer{
      on_text:
        Keyword.get(opts, :on_text, fn text, sent ->
          send(self(), {:on_text_called, text})
          %{sent | chars: sent.chars + String.length(text)}
        end),
      on_thinking:
        Keyword.get(opts, :on_thinking, fn text, sent ->
          send(self(), {:on_thinking_called, text})
          %{sent | thinking_chars: sent.thinking_chars + String.length(text)}
        end),
      on_signature:
        Keyword.get(opts, :on_signature, fn sig ->
          send(self(), {:on_signature_called, sig})
          :ok
        end)
    }
  end

  defp initial_state(_consumer) do
    {Client.new_accumulator(), nil, nil, %{chars: 0, thinking_chars: 0}}
  end

  describe "dispatch_step/3 — text vs. thinking routing" do
    test "a {:text, _} event folds into acc.text, not acc.thinking" do
      consumer = build_consumer()

      {acc, _resp, _err, _sent} =
        StreamConsumer.dispatch_step({:text, "Hello"}, initial_state(consumer), consumer)

      assert acc.text |> Enum.reverse() |> IO.iodata_to_binary() == "Hello"
      assert acc.thinking |> Enum.reverse() |> IO.iodata_to_binary() == ""
    end

    test "a {:thinking, _} event folds into acc.thinking, not acc.text" do
      consumer = build_consumer()

      {acc, _resp, _err, _sent} =
        StreamConsumer.dispatch_step(
          {:thinking, "Let me think..."},
          initial_state(consumer),
          consumer
        )

      assert acc.thinking |> Enum.reverse() |> IO.iodata_to_binary() == "Let me think..."
      assert acc.text |> Enum.reverse() |> IO.iodata_to_binary() == ""
    end

    test "a {:thinking_signature, _} event sets acc.thinking_signature, not acc.thinking" do
      consumer = build_consumer()

      {acc, _resp, _err, _sent} =
        StreamConsumer.dispatch_step(
          {:thinking_signature, "sig_xyz"},
          initial_state(consumer),
          consumer
        )

      assert acc.thinking_signature == "sig_xyz"
      assert acc.thinking |> Enum.reverse() |> IO.iodata_to_binary() == ""
      assert_received {:on_signature_called, "sig_xyz"}
    end

    test "subsequent text/thinking/signature events accumulate in their own slots" do
      consumer = build_consumer()

      state0 = initial_state(consumer)

      {acc1, _, _, _} =
        StreamConsumer.dispatch_step({:text, "Hello "}, state0, consumer)

      {acc2, _, _, _} =
        StreamConsumer.dispatch_step(
          {:thinking, "reasoning..."},
          {acc1, nil, nil, %{chars: 0, thinking_chars: 0}},
          consumer
        )

      {acc3, _, _, _} =
        StreamConsumer.dispatch_step(
          {:thinking_signature, "sig_abc"},
          {acc2, nil, nil, %{chars: 0, thinking_chars: 0}},
          consumer
        )

      {acc4, _, _, _} =
        StreamConsumer.dispatch_step(
          {:text, "world"},
          {acc3, nil, nil, %{chars: 0, thinking_chars: 0}},
          consumer
        )

      assert acc4.text |> Enum.reverse() |> IO.iodata_to_binary() == "Hello world"
      assert acc4.thinking |> Enum.reverse() |> IO.iodata_to_binary() == "reasoning..."
      assert acc4.thinking_signature == "sig_abc"
    end
  end

  describe "reduce/2 — end-to-end routing" do
    test "a stream of only thinking events produces a RunResponse with text: nil and thinking: <text>" do
      stream = [
        {:thinking, "Let me think"},
        {:thinking, " about this"},
        {:done, %{response: %RunResponse{text: nil}}}
      ]

      {acc, response, _error, _sent} = StreamConsumer.reduce(stream, build_consumer())

      assert acc.thinking |> Enum.reverse() |> IO.iodata_to_binary() == "Let me think about this"
      assert acc.text |> Enum.reverse() |> IO.iodata_to_binary() == ""
      assert response == %RunResponse{text: nil}
    end

    test "a mixed text + thinking stream produces text and thinking in their own slots" do
      stream = [
        {:thinking, "reasoning"},
        {:text, "answer "},
        {:thinking, " more reasoning"},
        {:text, "continuation"},
        {:done, %{response: %RunResponse{}}}
      ]

      {acc, _response, _error, _sent} = StreamConsumer.reduce(stream, build_consumer())

      assert acc.text |> Enum.reverse() |> IO.iodata_to_binary() == "answer continuation"
      assert acc.thinking |> Enum.reverse() |> IO.iodata_to_binary() == "reasoning more reasoning"
    end

    test "the consumer's on_text/on_thinking hooks fire for every text/thinking event" do
      stream = [
        {:text, "Hello "},
        {:thinking, "thinking..."},
        {:text, "world"}
      ]

      StreamConsumer.reduce(stream, build_consumer())

      assert_received {:on_text_called, "Hello "}
      assert_received {:on_thinking_called, "thinking..."}
      assert_received {:on_text_called, "world"}
    end
  end

  describe "reduce/2 — should_stop cooperative halt" do
    test "the should_stop callback halts the stream when it returns true" do
      # First call returns false (continue), second call returns
      # true (halt). The second text event should not be folded
      # into the accumulator.
      call_count = :counters.new(1, [])

      should_stop = fn ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        n >= 1
      end

      consumer = %StreamConsumer{
        build_consumer()
        | should_stop: should_stop
      }

      stream = [
        {:text, "first"},
        {:text, "second"}
      ]

      {acc, _response, _error, _sent} = StreamConsumer.reduce(stream, consumer)

      # Only the first event was processed before the halt.
      assert acc.text |> Enum.reverse() |> IO.iodata_to_binary() == "first"
    end
  end
end

defmodule Nest.LLM.MockClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.MockClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.Tool

  setup do
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> MockClient.stop() end)
    :ok
  end

  describe "lifecycle" do
    test "start_link is idempotent and clear resets state without crashing when the agent is not started" do
      MockClient.stop()
      assert MockClient.start_link() != nil
      assert MockClient.start_link() != nil
      assert MockClient.clear() == :ok
      MockClient.start_link()
    end
  end

  describe "default (no script set)" do
    test "run/2 returns a text stream with a non-empty text event and a stop finish reason" do
      {:ok, stream} = MockClient.run(%RunRequest{})

      events = Enum.to_list(stream)
      assert {:text, text} = hd(events)
      assert is_binary(text) and text != ""

      finish = Enum.find(events, &match?({:finish_reason, _}, &1))
      assert {:finish_reason, "stop"} = finish

      done = List.last(events)
      assert {:done, %{response: %RunResponse{text: ^text, stop_reason: "stop"}}} = done
    end
  end

  describe "set_response/1" do
    test "yields a single text event, finish reason, and done with the response" do
      MockClient.set_response("hello there")

      {:ok, stream} = MockClient.run(%RunRequest{})
      events = Enum.to_list(stream)

      assert events == [
               {:text, "hello there"},
               {:finish_reason, "stop"},
               {:done, %{response: %RunResponse{text: "hello there", stop_reason: "stop"}}}
             ]
    end

    test "is consumed once; the next call falls back to the default random text" do
      MockClient.set_response("first")
      {:ok, first} = MockClient.run(%RunRequest{})
      first_events = Enum.to_list(first)

      {:ok, second} = MockClient.run(%RunRequest{})
      second_events = Enum.to_list(second)

      assert {:text, "first"} = hd(first_events)
      assert {:text, first_random} = hd(second_events)
      assert first_random != "first"
      assert is_binary(first_random) and first_random != ""
    end
  end

  describe "set_tool_response/1" do
    test "yields preamble text, a tool_call_start + tool_call_delta per call, finish, and done" do
      MockClient.set_tool_response(%{
        text: "let me run that",
        tool_calls: [
          %{id: "call_1", name: "shell_cmd", arguments: %{"command" => "ls"}},
          %{id: "call_2", name: "read_file", arguments: %{"path" => "README.md"}}
        ]
      })

      {:ok, stream} = MockClient.run(%RunRequest{})
      events = Enum.to_list(stream)

      assert {:text, "let me run that"} = Enum.at(events, 0)

      assert {:tool_call_start, %{id: "call_1", name: "shell_cmd"}} = Enum.at(events, 1)
      assert {:tool_call_delta, %{id: "call_1", arguments_delta: delta1}} = Enum.at(events, 2)
      assert Jason.decode!(delta1) == %{"command" => "ls"}

      assert {:tool_call_start, %{id: "call_2", name: "read_file"}} = Enum.at(events, 3)
      assert {:tool_call_delta, %{id: "call_2", arguments_delta: delta2}} = Enum.at(events, 4)
      assert Jason.decode!(delta2) == %{"path" => "README.md"}

      assert {:finish_reason, "tool_calls"} = Enum.at(events, 5)

      assert {:done, %{response: response}} = List.last(events)
      assert response.text == "let me run that"
      assert length(response.tool_calls) == 2
      assert response.stop_reason == "tool_calls"
      [first_call, second_call] = response.tool_calls
      assert first_call.id == "call_1" and first_call.name == "shell_cmd"
      assert second_call.id == "call_2" and second_call.name == "read_file"
    end

    test "accepts arguments passed as nil and renders an empty JSON object" do
      MockClient.set_tool_response(%{
        text: "calling",
        tool_calls: [%{id: "c1", name: "shell_cmd", arguments: nil}]
      })

      {:ok, stream} = MockClient.run(%RunRequest{})

      [{:tool_call_delta, %{arguments_delta: delta}}] =
        Enum.filter(stream, &match?({:tool_call_delta, _}, &1))

      assert Jason.decode!(delta) == %{}
    end
  end

  describe "set_error/1" do
    test "run/2 returns a stream yielding the error event and the script is consumed" do
      MockClient.set_error("connection refused")

      assert {:ok, stream} = MockClient.run(%RunRequest{})
      assert [{:error, "connection refused"}, {:done, _}] = Enum.to_list(stream)

      {:ok, fallback} = MockClient.run(%RunRequest{})
      assert {:text, _} = hd(Enum.to_list(fallback))
    end
  end

  describe "set_stream_events/1" do
    test "yields the canned events verbatim when the list ends with :done" do
      canned = [
        {:thinking, "let me think"},
        {:thinking, " some more"},
        {:text, "answer"},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: "answer",
             thinking: "let me think some more",
             stop_reason: "stop"
           }
         }}
      ]

      MockClient.set_stream_events(canned)

      {:ok, stream} = MockClient.run(%RunRequest{})
      assert Enum.to_list(stream) == canned
    end

    test "appends a synthetic :done when the canned list does not end with one" do
      MockClient.set_stream_events([{:text, "only text"}])

      {:ok, stream} = MockClient.run(%RunRequest{})
      events = Enum.to_list(stream)

      assert length(events) == 2
      assert {:text, "only text"} = hd(events)
      assert {:done, %{response: %RunResponse{}}} = List.last(events)
    end

    test "in-band error event is preserved as part of the event sequence" do
      canned = [
        {:text, "partial"},
        {:error, :mid_stream_failure},
        {:done, %{response: %RunResponse{text: "partial"}}}
      ]

      MockClient.set_stream_events(canned)

      {:ok, stream} = MockClient.run(%RunRequest{})
      assert Enum.to_list(stream) == canned
    end
  end

  describe "format_request_payload/2" do
    test "renders model, messages, stream, and omits nil optional fields" do
      req = %RunRequest{
        model: "gpt-4o",
        messages: [
          {:system, %Nest.Messages.System{index: 0, content: "be brief"}},
          {:user, %Nest.Messages.User{index: 1, content: "hi"}}
        ]
      }

      payload = MockClient.format_request_payload(req)

      assert payload["model"] == "gpt-4o"
      assert payload["stream"] == true
      assert payload["temperature"] == nil
      assert payload["max_tokens"] == nil
      assert payload["top_p"] == nil
      assert payload["tool_choice"] == :auto
      refute Map.has_key?(payload, "tools")

      assert payload["messages"] == [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "includes tools as the OpenAI function-tool shape when tools are present" do
      tool = %Tool{
        name: "shell_cmd",
        description: "run a shell command",
        parameters_schema: %{
          type: "object",
          properties: %{command: %{type: "string"}},
          required: ["command"]
        },
        function: fn _, _ -> {:ok, ""} end
      }

      payload = MockClient.format_request_payload(%RunRequest{tools: [tool]})

      assert payload["tools"] == [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "shell_cmd",
                   "description" => "run a shell command",
                   "parameters" => %{
                     type: "object",
                     properties: %{command: %{type: "string"}},
                     required: ["command"]
                   }
                 }
               }
             ]
    end
  end

  describe "enumerable contract" do
    test "the returned stream is an Enumerable and supports Enum.count/1, Enum.take/2, Enum.member?/2" do
      MockClient.set_response("hello")

      {:ok, stream} = MockClient.run(%RunRequest{})

      assert Enumerable.impl_for(stream) != nil
      assert Enum.count(stream) == 3
      assert Enum.take(stream, 2) == [{:text, "hello"}, {:finish_reason, "stop"}]
      assert Enum.member?(stream, {:finish_reason, "stop"})
    end
  end
end

defmodule Nest.LLM.MockClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.MockClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.Tool
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

  # A 1x1 PNG, for the media wire shapes below.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

  setup do
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> MockClient.stop() end)
    :ok
  end

  defp shell_tool do
    %Tool{
      name: "shell-cmd",
      description: "run a shell command",
      parameters_schema: %{type: "object"},
      function: fn _args, _opts -> {:ok, ""} end
    }
  end

  defp media_part do
    %Part.Media{
      tool_call_id: nil,
      modality: :image,
      media_type: "image/png",
      data: @png,
      bytes: byte_size(Base.decode64!(@png)),
      path: "shot.png"
    }
  end

  describe "lifecycle" do
    test "start_link is idempotent and clear succeeds on a started queue" do
      MockClient.stop()
      assert MockClient.start_link() != nil
      # The second call is the one that lands on `{:error, {:already_started, _}}`.
      assert MockClient.start_link() != nil
      assert MockClient.clear() == :ok
    end

    test "stop is idempotent" do
      # The per-test teardown stops the queue, and an `on_exit` hook may stop it
      # again: the second call finds no process and must be a no-op.
      assert MockClient.stop() == :ok
      assert MockClient.stop() == :ok
    end

    test "clear and run survive a stopped queue" do
      # The window this pins is real: the teardown stops the per-agent queue
      # while a chat task may still be finishing, so `clear/0` and `run/2` can
      # each land with no queue registered for the owner. Neither may crash, and
      # `run/2` falls back to the default response rather than returning
      # nothing.
      MockClient.stop()
      assert MockClient.clear() == :ok

      {:ok, stream} = MockClient.run(%RunRequest{})
      assert [{:text, text}, {:finish_reason, "stop"}, {:done, _}] = Enum.to_list(stream)
      assert is_binary(text) and text != ""
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
    end
  end

  describe "set_tool_response/1" do
    test "yields preamble text, a tool_call_start + tool_call_delta per call, finish, and done" do
      MockClient.set_tool_response(%{
        text: "let me run that",
        tool_calls: [
          %{id: "call_1", name: "shell-cmd", arguments: %{"command" => "ls"}},
          %{id: "call_2", name: "file-read", arguments: %{"path" => "README.md"}}
        ]
      })

      {:ok, stream} = MockClient.run(%RunRequest{})
      events = Enum.to_list(stream)

      assert {:text, "let me run that"} = Enum.at(events, 0)

      assert {:tool_call_start, %{id: "call_1", name: "shell-cmd"}} = Enum.at(events, 1)
      assert {:tool_call_delta, %{id: "call_1", arguments_delta: delta1}} = Enum.at(events, 2)
      assert Jason.decode!(delta1) == %{"command" => "ls"}

      assert {:tool_call_start, %{id: "call_2", name: "file-read"}} = Enum.at(events, 3)
      assert {:tool_call_delta, %{id: "call_2", arguments_delta: delta2}} = Enum.at(events, 4)
      assert Jason.decode!(delta2) == %{"path" => "README.md"}

      assert {:finish_reason, "tool_calls"} = Enum.at(events, 5)

      assert {:done, %{response: response}} = List.last(events)
      assert response.text == "let me run that"
      assert length(response.tool_calls) == 2
      assert response.stop_reason == "tool_calls"
      [first_call, second_call] = response.tool_calls
      assert first_call.id == "call_1" and first_call.name == "shell-cmd"
      assert second_call.id == "call_2" and second_call.name == "file-read"
    end

    test "accepts arguments passed as nil and renders an empty JSON object" do
      MockClient.set_tool_response(%{
        text: "calling",
        tool_calls: [%{id: "c1", name: "shell-cmd", arguments: nil}]
      })

      {:ok, stream} = MockClient.run(%RunRequest{})

      [{:tool_call_delta, %{arguments_delta: delta}}] =
        Enum.filter(stream, &match?({:tool_call_delta, _}, &1))

      assert Jason.decode!(delta) == %{}
    end
  end

  describe "script selection for a request that carries no tools" do
    test "skips a queued tool response and keeps it for the next tool-bearing call" do
      MockClient.set_tool_response(%{
        text: "calling",
        tool_calls: [%{id: "c1", name: "shell-cmd", arguments: %{"command" => "ls"}}]
      })

      MockClient.set_response("plain answer")

      # `tools: nil` is the compactor's shape (`Dispatch` sends
      # `tools: nil, tool_choice: :none`), and such a call cannot consume a
      # tool-call script: the queued one is skipped and re-queued rather than
      # streamed to a caller that asked for no tools.
      {:ok, stream} = MockClient.run(%RunRequest{tools: nil})

      assert [{:text, "plain answer"}, {:finish_reason, "stop"}, {:done, _}] =
               Enum.to_list(stream)

      # The skipped script is still queued, and the next call that does carry
      # tools gets it.
      {:ok, tool_stream} = MockClient.run(%RunRequest{tools: [shell_tool()]})

      assert {:tool_call_start, %{id: "c1", name: "shell-cmd"}} =
               Enum.at(Enum.to_list(tool_stream), 1)
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
  end

  describe "format_request_payload/2" do
    test "renders model, messages, stream, and omits nil optional fields" do
      req = %RunRequest{
        model: "gpt-4o",
        messages: [
          {:system,
           %Nest.Messages.System{index: 0, parts: [%Nest.Messages.Part.Text{text: "be brief"}]}},
          {:user, %Nest.Messages.User{index: 1, parts: [%Nest.Messages.Part.Text{text: "hi"}]}}
        ]
      }

      payload = MockClient.format_request_payload(req)

      assert payload["model"] == "gpt-4o"
      assert payload["stream"] == true
      assert payload["temperature"] == nil
      assert payload["max_tokens"] == nil
      assert payload["top_p"] == nil
      assert payload["tool_choice"] == :auto

      assert payload["messages"] == [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "includes tools as the OpenAI function-tool shape when tools are present" do
      tool = %Tool{
        name: "shell-cmd",
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
                   "name" => "shell-cmd",
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

  describe "the wire shapes the replay harness depends on" do
    test "renders an assistant tool_use as OpenAI function tool_calls" do
      req = %RunRequest{
        messages: [
          {:assistant,
           %Assistant{
             index: 0,
             parts: [
               %Part.Text{text: "on it"},
               %Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{"command" => "ls"}},
               %Part.ToolUse{id: "call_2", name: "file-read", arguments: ~s({"path":"a.md"})}
             ],
             api_logs: []
           }}
        ]
      }

      assert [%{"role" => "assistant", "content" => "on it", "tool_calls" => [first, second]}] =
               MockClient.format_request_payload(req)["messages"]

      assert first["id"] == "call_1"
      assert first["type"] == "function"
      assert first["function"]["name"] == "shell-cmd"
      assert Jason.decode!(first["function"]["arguments"]) == %{"command" => "ls"}

      # Arguments already carried as a JSON string pass through verbatim: the
      # mock must not re-encode what a restored row already holds.
      assert second["function"]["arguments"] == ~s({"path":"a.md"})
    end

    test "renders a user message carrying media as a content array" do
      # The user-role media branch is the shape a build with a wider vocabulary
      # (or a future upload) leaves behind, so the part is built directly: a
      # media part is still shown in the panel, so it cannot silently vanish
      # from the request either.
      req = %RunRequest{
        messages: [{:user, %User{index: 1, parts: [%Part.Text{text: "look"}, media_part()]}}]
      }

      assert [%{"role" => "user", "content" => [text_block, image]}] =
               MockClient.format_request_payload(req)["messages"]

      assert text_block == %{"type" => "text", "text" => "look"}
      assert image["type"] == "image"
      assert image["source"] == %{"type" => "base64", "media_type" => "image/png", "data" => @png}

      # With no text part there is nothing to hoist, and an empty text block is
      # omitted rather than sent — it is not valid content.
      req = %RunRequest{messages: [{:user, %User{index: 1, parts: [media_part()]}}]}

      assert [%{"role" => "user", "content" => [%{"type" => "image"}]}] =
               MockClient.format_request_payload(req)["messages"]
    end

    test "a request with no tools at all omits the tools key" do
      # `nil` and `[]` are both "no tools" — the mock is total over the two
      # shapes — and neither puts a `tools` key on the wire.
      for tools <- [nil, []] do
        refute Map.has_key?(MockClient.format_request_payload(%RunRequest{tools: tools}), "tools")
      end
    end
  end

  describe "enumerable contract" do
    test "the returned stream is re-enumerable and supports Enum.count/1, Enum.take/2, Enum.member?/2" do
      MockClient.set_response("hello")

      {:ok, stream} = MockClient.run(%RunRequest{})

      assert Enum.count(stream) == 3
      assert Enum.take(stream, 2) == [{:text, "hello"}, {:finish_reason, "stop"}]
      assert Enum.member?(stream, {:finish_reason, "stop"})
    end
  end
end

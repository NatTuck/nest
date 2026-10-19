defmodule Nest.Agents.Agent.RestoreTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Restore` — the on-demand request-log
  rebuild helper.

  Covers `rebuild_request_api_logs/4`: the wire-format request
  payload is built with the same
  `client_config.client.format_request_payload/2` the live path
  uses (asserted by comparing against `MockClient`'s own output
  for an equivalent `RunRequest`), and that `{:compaction, _}`
  markers in the preloaded sequence never reach the wire.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.Restore
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.Tool, as: ToolDef
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction, as: CompactionMessage
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool, as: ToolMsg
  alias Nest.Messages.User

  defp fixture_messages do
    [
      {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys prompt"}], api_logs: []}},
      {:user, %User{index: 1, parts: [%Part.Text{text: "first turn"}], api_logs: []}},
      {:assistant,
       %Assistant{
         index: 2,
         parts: [%Part.Text{text: "first reply"}],
         api_logs: [],
         finish_reason: "stop"
       }},
      {:user, %User{index: 3, parts: [%Part.Text{text: "second turn"}], api_logs: []}},
      {:tool,
       %Nest.Messages.Tool{
         index: 4,
         parts: [%Part.ToolResult{tool_call_id: "c1", name: "shell-cmd", content: "ok"}],
         api_logs: []
       }},
      {:assistant,
       %Assistant{
         index: 5,
         parts: [%Part.Text{text: "second reply"}],
         api_logs: [],
         finish_reason: "stop"
       }}
    ]
  end

  defp fixture_state do
    tools = [
      %ToolDef{
        name: "shell-cmd",
        description: "run a shell command",
        parameters_schema: %{"type" => "object"},
        function: fn _, _ -> {:ok, "ok"} end
      }
    ]

    client_config = %ClientConfig{
      client: MockClient,
      base_url: "https://test/api",
      api_key: "test-key",
      receive_timeout: 5_000,
      model: "test-model",
      thinking_effort: :high
    }

    %Nest.Agents.Agent{
      name: "test-agent",
      model: %{name: "test-model", provider: "test"},
      client_config: client_config,
      tools: tools,
      chat_state: %ChatState{messages: fixture_messages()},
      live: %ChatState.Live{api_log_sequences: %{}}
    }
  end

  describe "rebuild_request_api_logs/4" do
    test "id is formatted as '<message_index>.<sequence>' to match Broadcasts.next_api_log_id/2" do
      state = fixture_state()

      rebuilt =
        Restore.rebuild_request_api_logs(state, fixture_messages(), 3, state.client_config)

      assert rebuilt.type == :request
      assert rebuilt.id == "003.000"
      assert is_struct(rebuilt.timestamp, DateTime)
    end

    test "payload matches the client's wire format for the same RunRequest slice" do
      # Compare to what MockClient would produce for the same
      # `messages[0..3]` slice (system + first user + first
      # assistant + target user). This pins that the rebuild
      # uses the SAME wire format the live path uses — no
      # deviation possible.
      messages = fixture_messages()
      state = fixture_state()

      rebuilt = Restore.rebuild_request_api_logs(state, messages, 3, state.client_config)
      slice = Enum.take(messages, 4)

      expected_request = %RunRequest{
        messages: slice,
        tools: state.tools,
        tool_choice: :auto,
        model: state.client_config.model,
        thinking_effort: state.client_config.thinking_effort,
        stream: true,
        metadata: %{}
      }

      assert rebuilt.payload == MockClient.format_request_payload(expected_request, [])
    end

    test "a tool-less agent rebuilds with no tools and tool_choice :none" do
      state = %{fixture_state() | tools: []}
      messages = fixture_messages()

      rebuilt = Restore.rebuild_request_api_logs(state, messages, 1, state.client_config)

      refute Map.has_key?(rebuilt.payload, "tools")
      assert rebuilt.payload["tool_choice"] == :none
    end

    # Regression: the `entire-ox` BEAM-restart crash. The
    # preloaded sequence carried `{:compaction, _}` tuples
    # mid-stream, and `OpenAIClient.message_to_wire/1` has no
    # clause for `:compaction`. The live path doesn't see this
    # because `state.chat_state.messages` excludes compaction
    # markers; the rebuild path draws from the full sequence
    # and must filter.
    test "rebuilt payload does NOT include compaction marker rows (entire-ox regression)" do
      preloaded_with_compaction = [
        {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}},
        {:user, %User{index: 1, parts: [%Part.Text{text: "u1"}], api_logs: []}},
        {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "a1"}]}},
        {:user, %User{index: 3, parts: [%Part.Text{text: "u2"}], api_logs: []}},
        {:tool,
         %ToolMsg{
           index: 4,
           parts: [
             %Part.ToolResult{tool_call_id: "c1", name: "shell-cmd", content: "ok"}
           ],
           api_logs: []
         }},
        {:assistant, %Assistant{index: 5, parts: [%Part.Text{text: "a2"}]}},
        {:compaction,
         %CompactionMessage{
           index: 6,
           archived_count: 6,
           occurred_at: nil,
           metadata: nil
         }},
        {:user,
         %User{
           index: 7,
           parts: [%Part.Text{text: "u3 after compaction"}],
           api_logs: []
         }}
      ]

      state = fixture_state()

      # The crucial assertion: calling rebuild_request_api_logs
      # for index 7 (which would otherwise include the
      # compaction at 6 in its slice) must NOT crash and must
      # NOT include the compaction row in the wire payload.
      rebuilt =
        Restore.rebuild_request_api_logs(state, preloaded_with_compaction, 7, state.client_config)

      # Flatten the wire messages (MockClient's `message_to_wire/1`
      # is inconsistent — system/assistant/tool return lists,
      # user returns a single map; the real OpenAI client
      # `flat_map`s everything). The flatten normalizes the
      # assertion without depending on MockClient's quirks.
      wire_messages =
        rebuilt.payload["messages"]
        |> List.flatten()
        |> Enum.filter(&is_map/1)

      # The compaction marker must NOT appear in the wire payload.
      # (Without the fix, `OpenAIClient.message_to_wire({:compaction, _})`
      # has no clause and the rebuild crashes with a CaseClauseError.)
      refute Enum.any?(wire_messages, &(&1["role"] == "compaction"))

      # Compactness: 8 preloaded elements minus the compaction
      # marker = 7 wire messages (1 system + 4 user + 2 assistant,
      # in order — the {:tool, _} maps to role "user" in the
      # Anthropic/Mock wire format).
      assert Enum.count(wire_messages) == 7

      # 3 user messages (u1, u2, u3) + 1 tool-result user = 4 user
      assert Enum.count(wire_messages, &(&1["role"] == "user")) == 4
      assert Enum.count(wire_messages, &(&1["role"] == "assistant")) == 2
      assert Enum.count(wire_messages, &(&1["role"] == "system")) == 1
    end

    test "rebuild works for an index BEFORE a compaction marker (negative case)" do
      # Same preloaded sequence as the regression test above.
      # Rebuilding for user@1 (slice = [system@0, user@1])
      # doesn't cross the marker at index 6, so no filter
      # fires. The slice stays at length 2.
      preloaded_with_compaction = [
        {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}},
        {:user, %User{index: 1, parts: [%Part.Text{text: "u1"}], api_logs: []}},
        {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "a1"}]}},
        {:compaction,
         %CompactionMessage{
           index: 3,
           archived_count: 3,
           occurred_at: nil,
           metadata: nil
         }}
      ]

      state = fixture_state()

      rebuilt =
        Restore.rebuild_request_api_logs(state, preloaded_with_compaction, 1, state.client_config)

      wire_messages = rebuilt.payload["messages"]
      assert Enum.count(wire_messages) == 2
      assert hd(wire_messages)["role"] == "system"
      assert Enum.at(wire_messages, 1)["role"] == "user"
    end
  end
end

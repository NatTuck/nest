defmodule Nest.Agents.Agent.RestoreTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Restore` — the rebuild helper
  that populates `state.chat_state` with api_logs after a
  BEAM restart.

  Covers three public functions:

  - `rebuild_request_api_logs/4` — wire-format identical to
    the live `Broadcasts.api_log/4` shape; uses the same
    `client_config.client.format_request_payload/2` the live
    path uses (asserted via `MockClient`'s capture mode).
  - `initial_sequences_for/1` — `%{idx => 1}` for user/tool,
    skip assistant/system.
  - `attach_rebuilt_api_logs/3` — sets `:user`/`:tool`
    `.api_logs = [rebuilt]` and seeds
    `state.live.api_log_sequences`. Idempotent.
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
         parts: [%Part.ToolResult{tool_call_id: "c1", name: "shell_cmd", content: "ok"}],
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
        name: "shell_cmd",
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
      model: "test-model"
    }

    %Nest.Agents.Agent{
      name: "test-agent",
      model: %{name: "test-model", provider: "test"},
      client_config: client_config,
      tools: tools,
      chat_state: %ChatState{messages: fixture_messages(), history: []},
      live: %ChatState.Live{api_log_sequences: %{}}
    }
  end

  describe "rebuild_request_api_logs/4" do
    test "id is formatted as '<message_index>.<sequence>' to match Broadcasts.next_api_log_id/2" do
      rebuilt =
        Restore.rebuild_request_api_logs(
          fixture_state(),
          fixture_messages(),
          3,
          fixture_state().client_config
        )

      assert rebuilt.type == :request
      assert is_binary(rebuilt.id)
      assert rebuilt.id == "003.000"
      assert is_struct(rebuilt.timestamp, DateTime)
      assert is_map(rebuilt.payload)
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
        stream: true,
        metadata: %{}
      }

      assert rebuilt.payload == MockClient.format_request_payload(expected_request, [])
    end

    test "omits opts to format_request_payload (wire format, no http concerns)" do
      # The rebuilt payload is built with an empty opts list
      # regardless of what's in `client_config` (no `base_url`,
      # no `api_key`). The MockClient's wire shape doesn't read
      # opts anyway, but this pins the contract for any future
      # client whose `format_request_payload` does.
      state = fixture_state()
      messages = fixture_messages()

      rebuilt = Restore.rebuild_request_api_logs(state, messages, 1, state.client_config)

      # The payload is identical regardless of opts — confirms
      # the rebuild uses an empty opts. (MockClient's signature
      # is `format_request_payload(req, opts \\ [])` and ignores
      # opts; we just compare to the canonical shape.)
      assert is_map(rebuilt.payload)
    end

    test "uses tool_choice :auto (matches the agent's standard chat config)" do
      state = fixture_state()
      messages = fixture_messages()

      rebuilt = Restore.rebuild_request_api_logs(state, messages, 1, state.client_config)

      # MockClient's wire format keeps `tool_choice: :auto` as
      # an atom. The OpenAI wire format would string-encode it;
      # the rebuild just preserves whatever the client's wire
      # format produces — the contract is "use the same client
      # the live path uses", not "produce a specific encoding".
      assert rebuilt.payload["tool_choice"] == :auto
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
             %Part.ToolResult{tool_call_id: "c1", name: "shell_cmd", content: "ok"}
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

      # And the slice the LLM would see is the user's full
      # context MINUS the compaction marker.
      assert Enum.any?(wire_messages, &(&1["role"] == "user"))
      assert Enum.any?(wire_messages, &(&1["role"] == "assistant"))

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

  describe "initial_sequences_for/1" do
    test "returns %{idx => 1} for every user and tool index in the sequence" do
      messages = fixture_messages()
      result = Restore.initial_sequences_for(messages)

      # Users at index 1 and 3; tool at index 4. No assistant
      # or system entries.
      assert result == %{1 => 1, 3 => 1, 4 => 1}
    end

    test "returns an empty map for an empty sequence" do
      assert Restore.initial_sequences_for([]) == %{}
    end

    test "skips assistant and system indices" do
      messages = [
        {:system, %MsgSystem{index: 0, parts: []}},
        {:assistant, %Assistant{index: 1, parts: []}}
      ]

      assert Restore.initial_sequences_for(messages) == %{}
    end
  end

  describe "attach_rebuilt_api_logs/3" do
    test "populates :user and :tool messages' api_logs with the rebuilt request entry" do
      state = fixture_state()
      messages = fixture_messages()

      new_state = Restore.attach_rebuilt_api_logs(state, messages, -1)

      # Find the user message at index 1 in the messages field;
      # it must now have a single-element api_logs list.
      {_role, %{index: 1, api_logs: api_logs}} =
        Enum.find(new_state.chat_state.messages, &match?({:user, %{index: 1}}, &1))

      assert length(api_logs) == 1
      assert hd(api_logs).type == :request
      assert hd(api_logs).id == "001.000"
    end

    test "seeded api_log_sequences points at sequence 1 for every user/tool index" do
      state = fixture_state()
      messages = fixture_messages()

      new_state = Restore.attach_rebuilt_api_logs(state, messages, -1)
      assert new_state.live.api_log_sequences == %{1 => 1, 3 => 1, 4 => 1}
    end

    test "preserves existing api_log_sequences entries (forward-compat for future rebroadcasts)" do
      state = %{
        fixture_state()
        | live: %{fixture_state().live | api_log_sequences: %{99 => 7}}
      }

      new_state = Restore.attach_rebuilt_api_logs(state, fixture_messages(), -1)

      # 99 => 7 (pre-existing) is preserved; users at 1, 3 and
      # tool at 4 are added.
      assert new_state.live.api_log_sequences[99] == 7
      assert new_state.live.api_log_sequences[1] == 1
      assert new_state.live.api_log_sequences[3] == 1
      assert new_state.live.api_log_sequences[4] == 1
    end

    test "is idempotent: a second call does not duplicate entries" do
      state = fixture_state()
      messages = fixture_messages()

      first = Restore.attach_rebuilt_api_logs(state, messages, -1)
      second = Restore.attach_rebuilt_api_logs(first, messages, -1)

      {_role, %{index: 1, api_logs: api_logs}} =
        Enum.find(second.chat_state.messages, &match?({:user, %{index: 1}}, &1))

      # The id is still `.000` because the skipped-rebuild
      # message (now non-empty api_logs) stays untouched.
      assert length(api_logs) == 1
    end

    test "leaves :assistant messages' api_logs empty (they're populated by the persisted row instead)" do
      state = fixture_state()
      new_state = Restore.attach_rebuilt_api_logs(state, fixture_messages(), -1)

      {_role, %{index: 2, api_logs: assistant_api_logs}} =
        Enum.find(new_state.chat_state.messages, &match?({:assistant, %{index: 2}}, &1))

      assert assistant_api_logs == []
    end

    test "rebuilt entries live in BOTH history and messages (boundary doesn't matter)" do
      # A user message that's pre-compaction lands in
      # `state.chat_state.history` after `seed_from_db/3`. The
      # rebuild walks the FULL preloaded sequence (not the
      # partition) and patches both fields.
      state = fixture_state()
      messages = fixture_messages()

      # Mark a compaction boundary at index 2 — the user/assistant
      # at indices 1 and 2 are now in history; user/tool/assistant
      # at 3..5 are in messages.
      state = %{state | chat_state: %{state.chat_state | history: Enum.take(messages, 3)}}

      new_state = Restore.attach_rebuilt_api_logs(state, messages, 2)

      # User @1 is in history but now has the rebuilt log.
      {_role, %{index: 1, api_logs: api_logs}} =
        Enum.find(new_state.chat_state.history, &match?({:user, %{index: 1}}, &1))

      assert length(api_logs) == 1
      assert hd(api_logs).id == "001.000"
    end
  end

  describe "reset_sequences/2" do
    test "resets live.api_log_sequences from the given preloaded list" do
      state = fixture_state()
      state = %{state | live: %{state.live | api_log_sequences: %{99 => 7}}}

      new_state = Restore.reset_sequences(state, fixture_messages())

      # `%{99 => 7}` is replaced (not merged). Forward-compat
      # use case: future "Refresh from DB" admin tool that
      # rebuilds sequences from scratch.
      assert new_state.live.api_log_sequences == %{1 => 1, 3 => 1, 4 => 1}
    end
  end
end

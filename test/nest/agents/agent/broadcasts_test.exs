defmodule Nest.Agents.Agent.BroadcastsTest do
  @moduledoc """
  Tests for the centralized `chat:error` broadcast path
  (`Nest.Agents.Agent.Broadcasts.error/3` and `error/4`).

  These are the contract:

    * `error/4` is the canonical entry point. It logs the
      error on the server and broadcasts a `chat:error` event
      whose `content` ends with `[Source: <module>/<n>]` so
      the UI shows where the error originated.
    * `error/3` (no source) is the backward-compat form. It
      still logs at error level and broadcasts the message
      verbatim (no source tag appended).
    * The server log entry always includes `chat:error`,
      `agent_id`, `message_index`, and `source` (or
      `source=unknown` for the unsourced form), plus the
      error message itself.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.PubSub

  setup do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(PubSub, "agent:#{agent_id}")
    {:ok, agent_id: agent_id}
  end

  describe "error/4 (canonical form with source)" do
    test "appends [Source: ...] to the user-facing message", %{agent_id: agent_id} do
      capture_log(fn ->
        Broadcasts.error(agent_id, 5, "Something broke", "Foo.bar/2")

        assert_receive {:chat_error, %{index: 5, content: content}}, 500

        assert content == "Something broke\n[Source: Foo.bar/2]"
      end)
    end

    test "logs the error at error level with structured context", %{agent_id: agent_id} do
      log =
        capture_log(fn ->
          Broadcasts.error(agent_id, 7, "Connection failed", "LLMRunner.handle_failed_response/3")
        end)

      assert log =~ "[error]"
      assert log =~ "chat:error"
      assert log =~ "msg_index=7"
      assert log =~ "source=LLMRunner.handle_failed_response/3"
      assert log =~ "Connection failed"
    end

    test "truncates very long messages in the server log", %{agent_id: agent_id} do
      long_msg = String.duplicate("a", 1_000)

      log =
        capture_log(fn ->
          Broadcasts.error(agent_id, 1, long_msg, "Foo.bar/2")
        end)

      # The user-facing message in the broadcast is NOT truncated
      # (the UI needs the full text), but the server log entry is.
      # The content is `long_msg` plus a trailing `\n[Source: Foo.bar/2]`
      # tag (20 bytes), so the broadcast content is 1,020 bytes.
      assert_receive {:chat_error, %{content: content}}, 500
      assert byte_size(content) == 1_020
      assert String.starts_with?(content, long_msg)
      assert String.ends_with?(content, "\n[Source: Foo.bar/2]")

      # The server log has a `(truncated)` marker — the 1,000-byte
      # message is sliced to 500 bytes plus a 14-byte suffix.
      assert log =~ "...(truncated)"
    end

    test "ignores an empty source string (treats it as no source)", %{agent_id: agent_id} do
      capture_log(fn ->
        Broadcasts.error(agent_id, 1, "msg", "")

        assert_receive {:chat_error, %{content: content}}, 500
        # Empty source is filtered out by `tag_source/2` — only
        # non-empty sources get the `[Source: ...]` suffix.
        assert content == "msg"
      end)
    end
  end

  describe "error/3 (backward-compat, no source)" do
    test "broadcasts the message verbatim (no [Source: ...] tag)", %{agent_id: agent_id} do
      capture_log(fn ->
        Broadcasts.error(agent_id, 2, "Plain error")

        assert_receive {:chat_error, %{index: 2, content: "Plain error"}}, 500
      end)
    end

    test "still logs the error at error level", %{agent_id: agent_id} do
      log =
        capture_log(fn ->
          Broadcasts.error(agent_id, 3, "Server-side issue")
        end)

      assert log =~ "[error]"
      assert log =~ "chat:error"
      assert log =~ "msg_index=3"
      # No source was passed — the log entry says so explicitly.
      assert log =~ "source=unknown"
      assert log =~ "Server-side issue"
    end
  end

  describe "delta_tool_use_start / delta_tool_use_delta (live tool-call streaming)" do
    # These broadcasts surface Anthropic / OpenAI tool-use events
    # as `chat:delta` events so the JS streaming partial can
    # render an in-flight `clone_agent` (or any other) tool call
    # before the assistant message finalizes. Without this, the
    # user sees only the thinking block until the message lands
    # and the bubble "pops" with a tool call at the end.

    test "delta_tool_use_start carries id, name, and the block index", %{agent_id: agent_id} do
      Broadcasts.delta_tool_use_start(agent_id, 7, "call_abc", "clone_agent", 0)

      assert_receive {:chat_delta,
                      %{
                        index: 7,
                        part_type: :tool_use_start,
                        tool_call_id: "call_abc",
                        tool_call_name: "clone_agent",
                        tool_call_block_index: 0,
                        content: "",
                        chars_start: 0,
                        chars_end: 0
                      }},
                     500
    end

    test "delta_tool_use_delta carries the resolved id and the argument fragment", %{
      agent_id: agent_id
    } do
      Broadcasts.delta_tool_use_delta(agent_id, 7, "call_abc", 0, ~s({"instru))

      assert_receive {:chat_delta,
                      %{
                        index: 7,
                        part_type: :tool_use_delta,
                        tool_call_id: "call_abc",
                        tool_call_block_index: 0,
                        content: ~s({"instru),
                        chars_start: 0,
                        chars_end: 0
                      }},
                     500
    end
  end
end

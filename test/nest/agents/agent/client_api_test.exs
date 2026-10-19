defmodule Nest.Agents.Agent.ClientAPITest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.ClientAPI` — the convenience
  get_* wrappers extracted from `Nest.Agents.Agent` so the
  GenServer module stays under the credo 500-line cap.

  Each function is a one-line `GenServer.call` that
  forwards to `IntrospectionHandler.handle/3`. Those calls
  are already exercised wherever `Nest.Agents.Agent` and
  `Nest.Agents` re-export them, so this file holds only the
  claims those call sites cannot make: the wire shape of a
  mid-tool-call partial, the `GenServer.call/3` failure
  bound, and the pre-turn `get_total_usage/1` placeholder.
  """

  use Nest.DataCase, async: true

  import Mimic
  import Nest.WireFormatAssertions

  alias Nest.Agents.Agent.ClientAPI
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Streaming

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    # The DataCase's automatic sandbox rollback covers
    # the agent rows (`Agents.create_agent/2`'s pre_spawn
    # insert is rolled back). A `for id <- ...;
    # delete_agent(id)` here would deadlock on
    # `DBConnection.OwnershipError` because `on_exit`
    # runs in `ExUnit.OnExitHandler`'s runner process
    # — no sandbox ownership. The same pattern is
    # documented in `agent_file_policy_test.exs`.
    on_exit(fn ->
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  describe "get_public_info/1" do
    test "a mid-tool-call partial is JSON-serializable on the wire" do
      # Regression for the lobby channel crash: `get_public_info/1`
      # returned a `partial` whose `currentType` was the raw
      # `{:tool_use, id}` tuple, so the channel's `init` push blew up
      # in `Jason.encode!`. Channel tests can't catch this because
      # `Phoenix.ChannelTest` uses `NoopSerializer` (no JSON encoding),
      # so assert against the real serializer here.
      {pid, _name} =
        AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus", provider: "model-studio"}})

      acc =
        Streaming.new(1)
        |> Streaming.append_text("checking")
        |> Streaming.start_tool_call("call_abc", "shell-cmd")
        |> Streaming.append_tool_call_args("call_abc", ~s({"command":))

      :sys.replace_state(
        pid,
        fn state ->
          %{state | live: %{state.live | streaming_acc: acc}}
        end,
        1_000
      )

      info = ClientAPI.get_public_info(pid)

      assert info.partial["currentType"] == ["tool_use", "call_abc"]
      assert_wire_encodable!(info.partial, "agent partial")
    end

    test "the optional timeout is the call's failure bound, and the default is unchanged" do
      {pid, _name} =
        AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus", provider: "model-studio"}})

      # Suspended, the agent's loop cannot answer, so a short bound *is* the
      # caller's exit. That is what makes the `1_000` the converted `#21` test
      # sites pass a real bound rather than a decorative one.
      :sys.suspend(pid, 1_000)

      assert catch_exit(ClientAPI.get_public_info(pid, 50)) ==
               {:timeout, {GenServer, :call, [pid, :get_public_info, 50]}}

      :sys.resume(pid, 1_000)

      # ...and the default is OTP's, unchanged for production callers.
      assert ClientAPI.get_public_info(pid).status == :idle
    end
  end

  describe "get_total_usage/1" do
    test "returns the zero-totals placeholder before any LLM call" do
      {pid, _name} =
        AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus", provider: "model-studio"}})

      totals = ClientAPI.get_total_usage(pid)
      assert totals.input_tokens == 0
      assert totals.output_tokens == 0
    end
  end
end

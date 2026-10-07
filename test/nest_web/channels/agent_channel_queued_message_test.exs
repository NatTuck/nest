defmodule NestWeb.AgentChannelQueuedMessageTest do
  @moduledoc """
  `chat:message` disposition for an agent that cannot start a turn right now:
  a busy agent (`:streaming`, `:executing_tools`, `:compacting`) queues the
  message — with the sender and the requested mode — for its next turn
  boundary, while a broken status is still refused and queues nothing.

  The `:compacting` case lives in `agent_channel_chat_test.exs` (beside the
  other status-disposition tests); this file covers the rest.
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Supervisor

  describe "chat:message dispositions" do
    test "a busy agent queues the message; a broken agent still refuses it", %{
      socket: socket,
      agent_id: id,
      space_id: space_id,
      user: user
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      # A busy agent queues the message for its next turn boundary — the
      # reply is `{:ok, _}`, not `agent_busy`, and the entry records the
      # sender and the requested mode verbatim (the mode is applied when the
      # message is delivered).
      for {status, n} <- Enum.with_index([:streaming, :executing_tools], 1) do
        set_status(agent_pid, status)
        content = "queued #{status}"

        ref = push(socket, "chat:message", %{"content" => content, "mode" => "plan"})
        assert_reply ref, :ok, %{}

        state = :sys.get_state(agent_pid)

        assert length(state.live.inbox) == n
        assert Machine.status_for(state.live.machine) == status

        assert %{content: ^content, kind: :user, from: from, mode: "plan"} =
                 List.last(state.live.inbox)

        assert from == user.username
      end

      # The queued human entries travel on the wire with their kind and mode,
      # and `pendingMessageCount` counts them.
      ref = push(socket, "chat:inbox", %{})
      assert_reply ref, :ok, %{"count" => 2, "messages" => messages}

      assert Enum.map(messages, &Map.take(&1, ["from", "content", "kind", "mode"])) == [
               %{
                 "from" => user.username,
                 "content" => "queued streaming",
                 "kind" => "user",
                 "mode" => "plan"
               },
               %{
                 "from" => user.username,
                 "content" => "queued executing_tools",
                 "kind" => "user",
                 "mode" => "plan"
               }
             ]

      assert Enum.all?(messages, &(is_binary(&1["timestamp"]) and &1["timestamp"] != ""))

      # The status reply carries the same count, so a reconnecting client
      # sees the queued human message.
      ref = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref, :ok, %{"pendingMessageCount" => 2}

      # A broken status still refuses the message and queues nothing new.
      before = :sys.get_state(agent_pid).live.inbox
      set_status(agent_pid, :needs_repair)

      ref = push(socket, "chat:message", %{"content" => "too late", "mode" => "plan"})
      assert_reply ref, :error, %{"reason" => "agent_status_needs_repair"}

      assert :sys.get_state(agent_pid).live.inbox == before
    end
  end

  describe "malformed chat:message payloads" do
    test "non-string or missing content is refused; a non-string mode means no mode", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)
      set_status(agent_pid, :streaming)

      # A map content would otherwise reach the agent and crash it when the
      # user message is built (idle) or the queue is combined (busy).
      ref = push(socket, "chat:message", %{"content" => %{"a" => 1}})
      assert_reply ref, :error, %{"reason" => "invalid_content"}

      # A payload with no content key used to match no clause at all, raising
      # inside the channel server.
      ref = push(socket, "chat:message", %{"mode" => "plan"})
      assert_reply ref, :error, %{"reason" => "invalid_content"}

      assert :sys.get_state(agent_pid).live.inbox == []

      # A non-binary mode is normalized to nil, so the wire contract stays
      # string-or-null.
      ref = push(socket, "chat:message", %{"content" => "hello", "mode" => 123})
      assert_reply ref, :ok, %{}

      state = :sys.get_state(agent_pid)
      assert [%{content: "hello", kind: :user, mode: nil}] = state.live.inbox

      reset_to_idle(agent_pid)
    end
  end

  # Fabricate an observable status (there is no real turn behind it). The
  # test's last probe leaves the agent in a blocked status — never one of the
  # in-flight busy ones — so the teardown's zero-in-flight assertion holds.
  defp set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | machine: Machine.status_to_machine(state.live.machine, status)
          }
      }
    end)
  end

  # Undo a fabricated status and the queue it collected, so the teardown's
  # zero-in-flight assertion holds.
  defp reset_to_idle(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | inbox: [],
              machine: Machine.status_to_machine(state.live.machine, :idle)
          }
      }
    end)
  end
end

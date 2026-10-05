defmodule Nest.Agents.Agent.InboxTest do
  @moduledoc """
  Tests for the async agent-to-agent inbox (`agents-send`): immediate
  delivery to an idle agent, queueing while busy, combined drain, the
  over-cap scratch-file offload, and the error paths.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.Part

  # A big-enough body to exceed the default 8000-token cap.
  @oversized String.duplicate("hello world ", 4_000)

  setup do
    {pid, name} = AgentTestHelpers.start_agent(%{})
    %{pid: pid, name: name}
  end

  test "delivery to an idle agent starts a turn with the message as a user message", %{pid: pid} do
    assert {:ok, :delivered} = Agent.deliver_message(pid, "peer", "do the thing")

    state = :sys.get_state(pid)

    assert Enum.any?(
             user_texts(state),
             &(&1 =~ "[Message from agent \"peer\"]" and &1 =~ "do the thing")
           )

    assert_receive {:chat_status, %{status: "idle"}}, 500
  end

  test "delivery to a busy agent queues and drains all queued messages together on idle", %{
    pid: pid
  } do
    set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_message(pid, "alice", "first message")
    assert_receive {:chat_inbox, %{count: 1}}, 500

    assert {:ok, :queued} = Agent.deliver_message(pid, "bob", "second message")
    assert_receive {:chat_inbox, %{count: 2}}, 500

    state = :sys.get_state(pid)
    assert Enum.map(state.live.inbox, & &1.from) == ["alice", "bob"]

    # Simulate the in-flight turn completing; the drain is synchronous
    # with the `:chat_idle` handling, so `:sys.get_state` below sees the
    # combined user message already appended.
    send(pid, {:chat_idle, make_ref()})
    state = :sys.get_state(pid)

    assert state.live.inbox == []
    assert_receive {:chat_inbox, %{count: 0}}, 500

    combined =
      Enum.find(user_texts(state), &(&1 =~ "first message" and &1 =~ "second message"))

    assert combined =~ "[Message from agent \"alice\"]"
    assert combined =~ "[Message from agent \"bob\"]"

    wait_idle(pid)
  end

  test "an over-cap combined message is offloaded to a scratch file and replaced by a pointer", %{
    pid: pid
  } do
    set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_message(pid, "alice", @oversized)
    send(pid, {:chat_idle, make_ref()})

    state = :sys.get_state(pid)

    pointer =
      Enum.find(user_texts(state), &(&1 =~ "queued message" and &1 =~ "saved to"))

    assert pointer =~ "You have 1 queued message from another agent"

    [path] = Path.wildcard(Path.join(state.tmp_path, "agent-inbox-*.txt"))
    assert File.read!(path) =~ "hello world"

    wait_idle(pid)
  end

  test "delivery to a broken agent returns an error and queues nothing", %{pid: pid} do
    set_status(pid, :needs_repair)

    assert {:error, {:status, :needs_repair}} = Agent.deliver_message(pid, "peer", "hello")
    assert :sys.get_state(pid).live.inbox == []
  end

  test "delivery is rejected when the inbox is full", %{pid: pid} do
    full =
      for n <- 1..100 do
        %{from: "peer", content: "msg #{n}", timestamp: DateTime.utc_now()}
      end

    :sys.replace_state(pid, fn state -> %{state | live: %{state.live | inbox: full}} end)

    assert {:error, :inbox_full} = Agent.deliver_message(pid, "peer", "one too many")
  end

  test "self-delivery is allowed", %{pid: pid, name: name} do
    assert {:ok, :delivered} = Agent.deliver_message(pid, name, "note to self")

    assert Enum.any?(user_texts(:sys.get_state(pid)), &(&1 =~ "note to self"))
    wait_idle(pid)
  end

  test "send_message/4 surfaces a missing target" do
    space_id = AgentTestHelpers.current_space_id()

    assert {:error, :not_found} =
             Agents.send_message(space_id, "alice", "does-not-exist", "hello")
  end

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

  defp wait_idle(pid) do
    assert Eventually.eventually(
             fn ->
               Machine.status_for(:sys.get_state(pid).live.machine) == :idle
             end,
             timeout: 500
           )
  end

  defp user_texts(state) do
    state.chat_state.messages
    |> Enum.flat_map(fn
      {:user, %{parts: parts}} -> [parts_text(parts)]
      _ -> []
    end)
  end

  defp parts_text(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end
end

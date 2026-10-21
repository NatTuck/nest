defmodule NestWeb.AgentChannelPaneTest do
  @moduledoc """
  The agent channel's pane handlers (issues #119/#120): the `pane:state` push,
  the `pane:sync` resync frame, and the three user actions — answer, drop and
  explain.

  The pane is per space, so the queue is filled by calling
  `Nest.Agents.Agent.Pane` directly (that is what the agent's `decisions-ask`
  tool does) and the assertions are on what the *channel* does with it.
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import ExUnit.CaptureLog
  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Pane
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence

  setup :verify_on_exit!

  defp ask(space_id, name, title) do
    Pane.ask(space_id, name, title, "The tradeoffs are ...", ["Postgres", "SQLite"])
  end

  test "pane:sync returns the space's queue and the join subscribed to its topic", %{
    socket: socket,
    agent_id: name,
    space_id: space_id
  } do
    assert {:ok, id} = ask(space_id, name, "Which database?")

    # The join subscribed this channel to the space's pane topic: the ask's
    # broadcast reaches it as a push.
    assert_push "pane:state",
                %{"spaceId" => ^space_id, "seq" => 1, "decisions" => [decision]}

    assert decision["id"] == id
    assert decision["title"] == "Which database?"
    assert decision["askedBy"] == name

    ref = push(socket, "pane:sync", %{})
    assert_reply ref, :ok, payload

    assert payload["seq"] == 1
    assert [%{"id" => ^id}] = payload["decisions"]
    # Only this agent's list — the frame is built per viewer.
    assert payload["todos"] == %{name => []}
  end

  test "answering removes the decision and delivers the answer to the asking agent", %{
    socket: socket,
    agent_id: name,
    space_id: space_id,
    user: user
  } do
    assert {:ok, id} = ask(space_id, name, "Which database?")

    ref =
      push(socket, "decisions:answer", %{
        "answers" => [%{"id" => id, "answer" => "Postgres"}]
      })

    assert_reply ref, :ok, %{"delivered" => [^id], "orphaned" => [], "failed" => [], "lost" => []}

    # Removed, in the same handler that delivered it.
    assert_push "pane:state", %{"decisions" => [], "seq" => 2}

    # The answer is the human's own words, through the same path `chat:message`
    # uses: a user row in the transcript, headered with the sender and mode.
    assert_push "chat:message", %{"role" => "user", "parts" => [%{"text" => text}]}
    assert text =~ "[From user @#{user.username}"
    assert text =~ "Decisions answered:"
    assert text =~ "- Which database?: Postgres"

    assert_receive {:chat_status, %{status: "idle"}}, 1_000
  end

  test "answers for one agent ride one message, and different agents get their own", %{
    socket: socket,
    agent_id: name,
    space_id: space_id
  } do
    peer = start_peer(space_id)
    assert {:ok, first} = ask(space_id, name, "Mine one")
    assert {:ok, second} = ask(space_id, name, "Mine two")
    assert {:ok, third} = ask(space_id, peer, "Theirs")

    ref =
      push(socket, "decisions:answer", %{
        "answers" => [
          %{"id" => first, "answer" => "a"},
          %{"id" => second, "answer" => "b"},
          %{"id" => third, "answer" => "c"}
        ]
      })

    assert_reply ref, :ok, %{
      "delivered" => [^first, ^second, ^third],
      "orphaned" => [],
      "failed" => []
    }

    # The joined agent's two answers are one row, and it does not carry the
    # peer's answer.
    assert_push "chat:message", %{"role" => "user", "parts" => [%{"text" => mine}]}
    assert mine =~ "- Mine one: a\n- Mine two: b"
    refute mine =~ "Theirs"

    # The peer's answer is its own row. This socket is joined to the *first*
    # agent, so the peer's row is not pushed to it: fence on the peer's idle
    # status and then read the row it wrote.
    assert_receive {:chat_status, %{name: ^peer, status: "idle"}}, 1_000
    assert [theirs] = user_texts(space_id, peer)
    assert theirs =~ "- Theirs: c"
    refute theirs =~ "Mine one"

    assert_receive {:chat_status, %{name: ^name, status: "idle"}}, 1_000
  end

  test "an answer to an orphaned question is marked, broadcast and not delivered", %{
    socket: socket,
    space_id: space_id
  } do
    ghost = "ghost-#{System.unique_integer([:positive])}"
    assert {:ok, id} = ask(space_id, ghost, "Nobody asked this")

    ref =
      push(socket, "decisions:answer", %{"answers" => [%{"id" => id, "answer" => "Postgres"}]})

    assert_reply ref, :ok, %{
      "delivered" => [],
      "orphaned" => [%{"id" => ^id, "reason" => reason}],
      "failed" => []
    }

    assert reason =~ "gone"

    # The mark comes from the server's broadcast — the pane never guesses.
    assert_push "pane:state",
                %{
                  "seq" => 2,
                  "decisions" => [
                    %{"id" => ^id, "orphaned" => true, "orphanedReason" => ^reason}
                  ]
                }

    # Explaining it has nobody to ask, so it stays drop-only and still succeeds
    # (the client asked, and there is nothing for the user to fix).
    ref = push(socket, "decisions:explain", %{"id" => id})
    assert_reply ref, :ok, %{}
  end

  test "an answer to a blocked agent fails and leaves the question answerable", %{
    socket: socket,
    space_id: space_id,
    user: user
  } do
    blocked = start_blocked_agent(space_id, user)
    assert {:ok, id} = ask(space_id, blocked, "Which database?")

    ref =
      push(socket, "decisions:answer", %{"answers" => [%{"id" => id, "answer" => "Postgres"}]})

    assert_reply ref, :ok, %{
      "delivered" => [],
      "orphaned" => [],
      "failed" => [%{"id" => ^id, "reason" => "agent_status_needs_repair"}]
    }

    # Nothing was removed and nothing was marked: `seq` is still 1, so no frame
    # was broadcast at all, and the question is still answerable.
    ref = push(socket, "pane:sync", %{})
    assert_reply ref, :ok, %{"seq" => 1, "decisions" => [%{"id" => ^id, "orphaned" => false}]}

    # An explain is refused the same way, rather than silently doing nothing.
    ref = push(socket, "decisions:explain", %{"id" => id})
    assert_reply ref, :error, %{"reason" => "agent_status_needs_repair"}
  end

  test "dropping questions removes them and tells only the live asking agent", %{
    socket: socket,
    agent_id: name,
    space_id: space_id
  } do
    ghost = "ghost-#{System.unique_integer([:positive])}"
    assert {:ok, live_id} = ask(space_id, name, "Live question")
    assert {:ok, ghost_id} = ask(space_id, ghost, "Ghost question")

    ref = push(socket, "decisions:drop", %{"ids" => [live_id, ghost_id]})
    assert_reply ref, :ok, %{}

    assert_push "pane:state", %{"seq" => 3, "decisions" => []}

    # A runtime notice, not a human message: the user dropped the question, and
    # the agent should stop waiting. The orphaned one has nobody to tell.
    assert_push "chat:message", %{"role" => "user", "parts" => [%{"text" => text}]}
    assert text =~ "nest runtime"
    assert text =~ "Live question"
    assert text =~ "dropped your question"
    refute text =~ "Ghost question"

    assert_receive {:chat_status, %{status: "idle"}}, 1_000
  end

  test "explaining asks for detail and leaves the question open", %{
    socket: socket,
    agent_id: name,
    space_id: space_id
  } do
    assert {:ok, id} = ask(space_id, name, "Which database?")

    ref = push(socket, "decisions:explain", %{"id" => id})
    assert_reply ref, :ok, %{}

    assert_push "chat:message", %{"role" => "user", "parts" => [%{"text" => text}]}
    assert text =~ ~s(Please explain "Which database?" in more detail.)

    # Not resolved and not removed: the explain broadcast nothing, and the
    # question is still in the queue.
    ref = push(socket, "pane:sync", %{})
    assert_reply ref, :ok, %{"seq" => 1, "decisions" => [%{"id" => ^id, "obsolete" => false}]}

    assert_receive {:chat_status, %{status: "idle"}}, 1_000
  end

  test "a guest on a shared agent gets no pane at all", %{
    socket: _owner_socket,
    agent_id: name,
    space_id: space_id,
    user: user
  } do
    # A guest may join a *shared* agent in this space. The pane belongs to the
    # space, though, so the guest must see none of it.
    shared = start_peer(space_id, shared: true, created_by_user_id: user.id)
    guest = create_user!("pane-guest")

    {:ok, guest_conn} = connect(NestWeb.UserSocket, %{"token" => AuthToken.sign(guest.id)})

    {:ok, _, guest_socket} =
      subscribe_and_join(guest_conn, NestWeb.AgentChannel, "agent:#{space_id}:#{shared}")

    for {event, payload} <- [
          {"pane:sync", %{}},
          {"decisions:answer", %{"answers" => []}},
          {"decisions:drop", %{"ids" => []}},
          {"decisions:explain", %{"id" => "d1"}}
        ] do
      ref = push(guest_socket, event, payload)
      assert_reply ref, :error, %{"reason" => "forbidden"}
    end

    # And the join did not subscribe it: the owner's channel receives the frame,
    # the guest's never does. The `:sys.get_state` is the barrier — it is queued
    # behind every message the guest's channel had already been sent, so a push
    # would already be in this mailbox when it returns.
    assert {:ok, _id} = ask(space_id, name, "Owner only")
    assert_push "pane:state", %{"spaceId" => ^space_id}

    # allowlist: barrier — anchor for refute_push "pane:state", 0
    _ = :sys.get_state(guest_socket.channel_pid, 1_000)
    refute_push "pane:state", _, 0

    Process.unlink(guest_socket.channel_pid)
    GenServer.stop(guest_socket.channel_pid, :normal)
  end

  test "an answer whose delivery fails after the removal is reported lost", %{
    socket: socket,
    agent_id: name,
    space_id: space_id
  } do
    assert {:ok, id} = ask(space_id, name, "Which database?")

    # The asking agent resolves during the pre-flight and is gone by the time
    # the answer is delivered — the one window in which the question has already
    # been removed and the answer cannot land.
    Mimic.allow(Nest.Agents, self(), socket.channel_pid)

    Mimic.stub(Nest.Agents, :chat, fn _space, _name, _body, _mode, _sender, _human? ->
      {:error, :not_found}
    end)

    log =
      capture_log(fn ->
        ref =
          push(socket, "decisions:answer", %{
            "answers" => [%{"id" => id, "answer" => "Postgres"}]
          })

        assert_reply ref, :ok, %{
          "delivered" => [],
          "orphaned" => [],
          "failed" => [],
          "lost" => [%{"id" => ^id, "reason" => "not_found"}]
        }
      end)

    assert log =~ "was not delivered"

    # Removed, because the take ran before the delivery attempt: the client's
    # next frame prunes the id, which is why this is `lost` and not `failed`.
    assert_push "pane:state", %{"decisions" => [], "seq" => 2}
  end

  test "a drop whose asking agent dies under the notice still answers", %{
    socket: socket,
    agent_id: name,
    space_id: space_id
  } do
    assert {:ok, id} = ask(space_id, name, "Which database?")

    # `notify_dropped/2` resolves the asking agent and then calls into it, and the
    # pid can die between the two: the agent traps exits, so `stop_agent/2` only
    # queues its `:shutdown` and the Registry still names it. The notice is
    # best-effort, so the drop must still be answered rather than taking the
    # channel down with it.
    Mimic.allow(Nest.Agents.Agent, self(), socket.channel_pid)

    Mimic.stub(Nest.Agents.Agent, :deliver_internal, fn _, _, _, _ -> exit(:noproc) end)

    ref = push(socket, "decisions:drop", %{"ids" => [id]})
    assert_reply ref, :ok, %{}

    # Removed anyway: the notice is a courtesy, the removal is the action.
    ref = push(socket, "pane:sync", %{})
    assert_reply ref, :ok, %{"decisions" => []}
  end

  test "a malformed pane payload is refused rather than acted on", %{socket: socket} do
    ref = push(socket, "decisions:answer", %{"answers" => [%{"id" => 1, "answer" => "x"}]})
    assert_reply ref, :error, %{"reason" => "invalid_payload"}

    ref = push(socket, "decisions:drop", %{})
    assert_reply ref, :error, %{"reason" => "invalid_payload"}

    ref = push(socket, "decisions:explain", %{"id" => "d404"})
    assert_reply ref, :error, %{"reason" => "decision_not_found"}
  end

  # ---- helpers ----

  # A second, live agent in the *same* space — the peer an answer to another
  # agent's question goes to while the client stays on the first agent's page.
  # It is created the documented way (`Agents.create_agent/3`) and then given
  # the two fixtures a spawned test agent needs: the sandbox connection the
  # turn's appends use, and the mock LLM client. `AgentTestHelpers` installs
  # both for the agent *it* starts; a peer in an existing space gets them here.
  defp start_peer(space_id, opts \\ []) do
    name = "peer#{System.unique_integer([:positive])}"

    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test(),
        shared: Keyword.get(opts, :shared, false),
        created_by_user_id: Keyword.get(opts, :created_by_user_id)
      )

    {:ok, pid} = Supervisor.get_agent(space_id, name)
    Sandbox.allow(Nest.Repo, self(), pid)

    _ =
      :sys.replace_state(
        pid,
        fn state ->
          %{state | client_config: %{state.client_config | client: MockClient}}
        end,
        1_000
      )

    :ok = Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.topic(space_id, name))
    AgentTestHelpers.ensure_cleanup(name)
    name
  end

  # A `:needs_repair` agent in the same space: the status an asking agent can be
  # in when the user's answer cannot be delivered. The start logs the corruption
  # it found at error level, and the capture asserts on that line rather than
  # merely silencing it.
  defp start_blocked_agent(space_id, user) do
    name = "blocked-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: nil,
        vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
        created_by_user_id: user.id
      })

    for message <- [
          system(0),
          user_row(1, "run"),
          assistant_tool(2, "call_1"),
          user_row(3, "still there?")
        ] do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end

    {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)

    log =
      capture_log(fn ->
        {:ok, _pid} = Supervisor.start_under_test(attrs)
      end)

    assert log =~ "loaded an invalid active message sequence"
    name
  end

  # A second, real user: `create_user/2` honours the `first-user` bootstrap only
  # while the users table is empty, so this is a plain member.
  defp create_user!(prefix) do
    username = "#{prefix}-#{System.unique_integer([:positive])}"

    {:ok, user, _role} =
      Accounts.create_user(%{username: username, password: "password123"}, "member")

    user
  end

  # The text of every user row in an agent's transcript.
  defp user_texts(space_id, name) do
    {:ok, messages} = Agents.get_messages(space_id, name)

    for {:user, %User{parts: parts}} <- messages,
        do: Enum.map_join(parts, "", & &1.text)
  end

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user_row(index, text) do
    {:user, %User{index: index, parts: [%Part.Text{text: text}]}}
  end

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end
end

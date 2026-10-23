defmodule NestWeb.LobbyChannelSpaceFeedTest do
  @moduledoc """
  The space feed's transport (`NestWeb.LobbyChannel.SpaceFeed`): the initial
  read, the composer's send, and the `user_note:created` push.

  The feed is `/space/:slug` — one table (`user_notes`) read by the human at one
  end of each row. These tests are about the *transport*: what a client is
  allowed to read, what a send becomes, and which frames reach which socket. The
  table's own rules are `Nest.NotesTest`'s.
  """

  use NestWeb.ChannelCase, async: true

  import Mimic

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.AddressTestHelpers
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Blueprints
  alias Nest.Notes
  alias Nest.Spaces

  setup :verify_on_exit!

  setup do
    # One human and one space owned by them. `space_with_human/2` makes both, so
    # the socket's user and the space's owner are the same row — which is what
    # `Notes.list_for/2` and `Authz.authorize_space_owner/2` both read.
    space = AddressTestHelpers.space_with_human("alice")
    alice = Accounts.get_user(space.created_by_user_id)

    # A second human, so "not one of alice's notes" is a real row in the same
    # space rather than a hypothetical one.
    _bob = AddressTestHelpers.human("bob")

    {:ok, space: space, alice: alice, token: AuthToken.sign(alice.id)}
  end

  describe "space_feed" do
    test "answers with the notes the caller is an end of, the mode catalog, and the default", %{
      space: space,
      token: token
    } do
      # A blueprint whose default mode is not `Nest.Modes.default/0`, so the
      # assertion can tell "read the blueprint" from "answered `act`".
      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "Feed #{System.unique_integer([:positive])}",
          root_vocation: "programmer",
          default_mode: "plan"
        })

      {:ok, with_blueprint} =
        Spaces.create_space(space.created_by_user_id, %{
          name: "feed-blueprint-#{System.unique_integer([:positive])}",
          slug: "feed-blueprint-#{System.unique_integer([:positive])}",
          workspace_path: AgentTestHelpers.default_test_workspace(),
          blueprint_id: blueprint.id
        })

      other_space = AddressTestHelpers.space_with_human("carol")

      # Both directions of alice's feed, in `id` order, plus two rows that are
      # not hers: one addressed to bob, one in another space.
      {:ok, first} = Notes.deliver(space.id, {:agent, "worker"}, {:user, "alice"}, "1", :query)

      {:ok, _bobs} = Notes.deliver(space.id, {:agent, "worker"}, {:user, "bob"}, "no", :agent)

      {:ok, second} =
        Notes.deliver(space.id, {:user, "alice"}, {:agent, "worker"}, "2", :agent)

      {:ok, _elsewhere} =
        Notes.deliver(other_space.id, {:agent, "worker"}, {:user, "alice"}, "3", :query)

      socket = join(token)

      ref = push(socket, "space_feed", %{"space_id" => space.id})
      assert_reply ref, :ok, %{"notes" => notes, "modes" => modes, "default_mode" => default}, 500

      # `id` is the order: the table's key is monotonic, so `inserted_at` is for
      # display only. Both directions are the one read — `first` is the agent's
      # note to alice and `second` is hers to the agent — and neither of the two
      # rows that are not hers is in the list.
      assert Enum.map(notes, & &1.id) == [first.id, second.id]
      # The catalog is the server's, and the default is the space's blueprint's.
      assert modes == Nest.Modes.names()
      assert default == "act"

      # ...and a space with a blueprint takes the blueprint's default.
      ref = push(socket, "space_feed", %{"space_id" => with_blueprint.id})
      assert_reply ref, :ok, %{"default_mode" => "plan", "notes" => []}, 500
    end

    test "refuses a space the caller is not in, and one that does not exist", %{
      space: space
    } do
      # Scoping is the same check `archive_space` makes, so the read can never
      # reach further than the subscription set `after_join` built.
      bob = Accounts.get_user_by_username("bob")
      socket = join(AuthToken.sign(bob.id))

      ref = push(socket, "space_feed", %{"space_id" => space.id})
      assert_reply ref, :error, %{"reason" => "forbidden"}, 500

      ref = push(socket, "space_feed", %{"space_id" => -1})
      assert_reply ref, :error, %{"reason" => "not_found"}, 500

      ref = push(socket, "space_feed", %{})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}, 500
    end
  end

  describe "user_note:created" do
    test "pushes a note the caller is an end of, and no other human's note", %{
      space: space,
      token: token
    } do
      socket = join(token)

      # The real insert, so the whole path is exercised: `Nest.Notes.deliver/5`
      # broadcasts on the space's topic, the channel is subscribed, and the
      # frame reaches this client.
      {:ok, mine} = Notes.deliver(space.id, {:agent, "worker"}, {:user, "alice"}, "hi", :query)

      assert_push "user_note:created", %{"note" => note}
      assert %Notes.UserNote{id: id, content: "hi", from_kind: :agent, to_kind: :user} = note
      assert id == mine.id

      # The row reaches the browser as the schema's own JSON — its `@derive`d
      # field list, which is the contract the feed renders against.
      assert %{"id" => ^id, "from_kind" => "agent", "inserted_at" => _} =
               Jason.decode!(Jason.encode!(note))

      # A note between two other humans is in the space and is none of alice's
      # business: the push applies the same predicate as the read.
      {:ok, _bobs} = Notes.deliver(space.id, {:user, "bob"}, {:agent, "worker"}, "no", :agent)
      settle(socket)
      refute_push "user_note:created", _, 0

      # ...and a note addressed to her still arrives, so the `refute_push` above
      # is not vacuous.
      {:ok, second} =
        Notes.deliver(space.id, {:agent, "worker"}, {:user, "alice"}, "again", :agent)

      assert_push "user_note:created", %{"note" => %Notes.UserNote{id: id}}
      assert id == second.id
    end
  end

  describe "send_note" do
    test "sends one query from the caller to the agent they picked", %{
      space: space,
      token: token
    } do
      socket = join(token)
      test_pid = self()

      stub_send_note(fn args ->
        send(test_pid, {:sent, args})
        {:ok, :queued}
      end)

      ref =
        push(socket, "send_note", %{
          "space_id" => space.id,
          "to" => "worker",
          "content" => "what is the status?",
          "mode" => "plan"
        })

      assert_reply ref, :ok, %{"disposition" => "queued"}, 500

      # The sender is the socket's user, built server-side (a client cannot
      # speak as somebody else), and the kind is a query — that is what obliges
      # the agent to answer.
      assert_receive {:sent, [space_id, from, to, content, kind, mode]}
      assert space_id == space.id
      assert from == "@alice"
      assert to == "worker"
      assert content == "what is the status?"
      assert kind == :query
      assert mode == "plan"
    end

    test "refuses a mode it does not know, an agent it cannot find, and a space it is not in",
         %{space: space, token: token} do
      socket = join(token)
      test_pid = self()

      stub_send_note(fn [_space_id, _from, to, _content, _kind, _mode] ->
        send(test_pid, {:sent, to})
        if to == "ghost", do: {:error, :not_found}, else: {:ok, :delivered}
      end)

      # A mode name no build implements would be stated in the message and
      # honoured by nobody, so it is refused before anything is sent.
      ref =
        push(socket, "send_note", %{
          "space_id" => space.id,
          "to" => "worker",
          "content" => "x",
          "mode" => "root"
        })

      assert_reply ref, :error, %{"reason" => "invalid_mode"}, 500

      # A blank note is not a note.
      ref =
        push(socket, "send_note", %{"space_id" => space.id, "to" => "worker", "content" => "  "})

      assert_reply ref, :error, %{"reason" => "blank_content"}, 500

      # The picker offered an agent the server no longer has: the refusal names
      # it, so the banner can say which.
      ref =
        push(socket, "send_note", %{"space_id" => space.id, "to" => "ghost", "content" => "x"})

      assert_reply ref, :error, %{"reason" => "agent_not_found", "target" => "ghost"}, 500

      # A push with no space in it cannot be routed at all.
      ref = push(socket, "send_note", %{"to" => "worker", "content" => "x"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}, 500

      # ...and a space this user is not in sends nothing at all.
      bob = Accounts.get_user_by_username("bob")
      bob_socket = join(AuthToken.sign(bob.id))

      ref =
        push(bob_socket, "send_note", %{
          "space_id" => space.id,
          "to" => "worker",
          "content" => "x"
        })

      assert_reply ref, :error, %{"reason" => "forbidden"}, 500

      # Only the ghost push reached the send path: the three refusals above it
      # never did.
      assert_received {:sent, "ghost"}
      refute_received {:sent, "worker"}
    end
  end

  # `Nest.Agents.send_note/6` is the boundary: what the channel owes is the
  # address it builds and the kind it asks for, and what it does with the
  # disposition. Stubbing it keeps these tests about the transport rather than
  # about starting an agent.
  defp stub_send_note(fun) do
    Mimic.stub(Nest.Agents, :send_note, fn space_id, from, to, content, kind, mode ->
      fun.([space_id, from, to, content, kind, mode])
    end)
  end

  defp join(token) do
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})
    {:ok, _reply, socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    # The join's own pushes, so they cannot be mistaken for a frame under test.
    # `broken_agents_updated` is also the barrier for the async task the join
    # starts: it does DB work on this test's sandbox connection, so waiting for
    # it is what keeps it from outliving the test's owner. The bound is the one
    # the other lobby helpers use for the same task.
    assert_push "init", %{}
    assert_push "broken_agents_updated", %{broken_agents: _}, 1_000
    # The stub is registered by the test process; the channel is a different
    # process, so it has to be allowed to see it.
    Mimic.allow(Nest.Agents, self(), socket.channel_pid)

    socket
  end
end

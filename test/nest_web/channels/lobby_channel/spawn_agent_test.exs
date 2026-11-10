defmodule NestWeb.LobbyChannel.SpawnAgentTest do
  @moduledoc """
  The lobby's `spawn_agent` action (#209): one more agent at the top of a space,
  a peer of its root.

  What is pinned here is the channel half — the reply carries the name the server
  settled on, the `agent:created` frame another session applies, the new agent is
  top-level (no parent, depth 0), and the refusals: a caller who does not own the
  space, a vocation that does not exist, a duplicate name, and a payload the
  client got wrong. The vocation and model resolution it leans on is
  `Nest.Spaces.resolve_agent_vocation/2`'s and `Agents.create_agent/3`'s,
  exercised through this action.
  """

  use NestWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.BlueprintsFixtures
  alias Nest.Name
  alias Nest.Repo
  alias Nest.Spaces
  alias Nest.VocationsFixtures
  alias NestWeb.LobbyChannel

  @model %{"name" => "qwen3.5-plus", "provider" => "model-studio"}

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, user, _role} =
      Accounts.create_user(%{username: "lobby-spawn", password: "password123"}, "first-user")

    {:ok, space_id} = AgentTestHelpers.create_test_space(%{}, user.id)
    # The default vocation is the catalogue's first; upserting is idempotent, so
    # this cannot race another test's read.
    _ = AgentTestHelpers.vocation_slug_for_test()

    {:ok, socket: join_as(user), user: user, space_id: space_id}
  end

  describe "handle_in(spawn_agent)" do
    test "an owner's spawn creates a top-level agent and announces it", %{
      socket: socket,
      space_id: space_id
    } do
      ref = push(socket, "spawn_agent", %{"space_id" => space_id, "model" => @model})

      assert_reply ref, :ok, %{"name" => name}, 500
      assert is_binary(name)
      AgentTestHelpers.ensure_cleanup(name)

      # The frame the sidebar tree is built from, on the space topic.
      assert_push "agent:created",
                  %{"name" => ^name, "space_id" => ^space_id, "parentId" => nil, "depth" => 0},
                  500

      # "Top level, peer with the root": no parent, depth 0, and it is in the
      # space's own list rather than only in the reply.
      info = info_for(space_id, name)
      assert info.parent_id == nil
      assert info.depth == 0
    end

    test "an explicit name is used, and a name is generated when none is given", %{
      socket: socket,
      space_id: space_id
    } do
      explicit = "helper-#{System.unique_integer([:positive])}"

      payload = %{"space_id" => space_id, "name" => explicit, "model" => @model}

      assert_reply push(socket, "spawn_agent", payload), :ok, %{"name" => ^explicit}, 500
      AgentTestHelpers.ensure_cleanup(explicit)

      payload = %{"space_id" => space_id, "model" => @model}

      assert_reply push(socket, "spawn_agent", payload), :ok, %{"name" => generated}, 500
      AgentTestHelpers.ensure_cleanup(generated)

      # A generated name is one the app would accept anywhere a name is checked,
      # not a placeholder the reply invented.
      assert generated != explicit
      assert Name.valid?(generated)
      assert info_for(space_id, generated).name == generated
    end

    test "an explicit vocation and model are honoured", %{socket: socket, space_id: space_id} do
      slug = AgentTestHelpers.vocation_slug_for_test()

      payload = %{"space_id" => space_id, "vocation" => slug, "model" => @model}

      assert_reply push(socket, "spawn_agent", payload), :ok, %{"name" => name}, 500
      AgentTestHelpers.ensure_cleanup(name)

      info = info_for(space_id, name)
      assert info.vocation_slug == slug
      assert info.model["name"] == "qwen3.5-plus"
      assert info.model["provider"] == "model-studio"
    end

    test "the default vocation is the space's blueprint root vocation", %{user: user} do
      root = VocationsFixtures.vocation_fixture()
      blueprint = BlueprintsFixtures.blueprint_fixture(%{root_vocation: root.slug})

      {:ok, space_id} = AgentTestHelpers.create_test_space(%{blueprint_id: blueprint.id}, user.id)

      payload = %{"space_id" => space_id, "model" => @model}

      assert_reply push(join_as(user), "spawn_agent", payload), :ok, %{"name" => name}, 500
      AgentTestHelpers.ensure_cleanup(name)

      # Nothing in the payload named a vocation, so the space's blueprint did —
      # the same rule its root agent is created under.
      assert info_for(space_id, name).vocation_slug == root.slug
    end

    test "an absent model is refused, rather than spawning a blocked agent", %{
      socket: socket,
      space_id: space_id
    } do
      # `Agents.create_agent/3` with an empty model map produces an agent that
      # starts blocked on `:model_missing` — a state to recover from, not a way
      # to spawn. The client always names a model (the dialog will not submit
      # without one), so a payload that does not is refused here.
      assert_reply push(socket, "spawn_agent", %{"space_id" => space_id}),
                   :error,
                   %{"reason" => "model_required"},
                   500

      assert Agents.list_agents_info_for_space(space_id) == []
    end

    test "a nil for an optional key means unset, as a JSON client sends it", %{
      socket: socket,
      user: user
    } do
      # A blueprint of this test's own makes the default decidable: the spawned
      # agent inherits its root vocation, whatever else the shared catalogue
      # holds. The fixture space has no blueprint, so its default would be the
      # catalogue's *first* — which under `async` is some other test's vocation.
      blueprint = BlueprintsFixtures.blueprint_fixture()
      {:ok, space_id} = AgentTestHelpers.create_test_space(%{blueprint_id: blueprint.id}, user.id)

      payload = %{"space_id" => space_id, "name" => nil, "vocation" => nil, "model" => @model}

      assert_reply push(socket, "spawn_agent", payload), :ok, %{"name" => name}, 500
      AgentTestHelpers.ensure_cleanup(name)

      # Unset, not a name of `nil` and not a refusal: the server generated one.
      assert Name.valid?(name)
      assert info_for(space_id, name).vocation_slug == blueprint.root_vocation
    end

    test "a caller who does not own the space is refused", %{space_id: space_id} do
      {:ok, other, _role} =
        Accounts.create_user(
          %{username: "lobby-spawn-other", password: "password123"},
          "invite-token"
        )

      payload = %{"space_id" => space_id, "model" => @model}

      assert_reply push(join_as(other), "spawn_agent", payload),
                   :error,
                   %{"reason" => "forbidden"},
                   500

      # Nothing was created: the refusal is the owner check's, not a failed
      # create.
      assert Agents.list_agents_info_for_space(space_id) == []
    end

    test "an archived space is refused rather than grown", %{
      socket: socket,
      space_id: space_id
    } do
      # The UI cannot reach this — an archived slug renders the restore notice,
      # not the feed — but the channel is the boundary, and the case that really
      # happens is a dialog left open while the space is archived from another
      # tab. `archive_space/1` stopped the space's agents and released its
      # sandbox, so an agent created now would be one nothing supervises.
      :ok = Spaces.archive_space(space_id)

      assert_reply push(socket, "spawn_agent", %{"space_id" => space_id, "model" => @model}),
                   :error,
                   %{"reason" => "space_archived"},
                   500

      assert Agents.list_agents_info_for_space(space_id) == []
    end

    test "a spawn that loses the race to an archive answers space_archived", %{
      socket: socket,
      space_id: space_id
    } do
      # The channel's own archived check reads the row *before* `create_agent/3`
      # renders and writes the agent's first messages, so an archive can land in
      # between. The start path then refuses it (`fetch_or_start_agent/2`
      # verifies after the process exists), and the reply has to carry the code
      # the dialog already words — not the generic create failure.
      Mimic.stub(Nest.Agents, :create_agent, fn _space, _model, _opts ->
        {:error, :space_archived}
      end)

      Mimic.allow(Nest.Agents, self(), socket.channel_pid)

      assert_reply push(socket, "spawn_agent", %{"space_id" => space_id, "model" => @model}),
                   :error,
                   %{"reason" => "space_archived"},
                   500
    end

    test "an unknown vocation is refused with the create path's code", %{
      socket: socket,
      space_id: space_id
    } do
      payload = %{"space_id" => space_id, "vocation" => "no-such-role", "model" => @model}

      log =
        capture_log(fn ->
          assert_reply push(socket, "spawn_agent", payload),
                       :error,
                       %{"reason" => "vocation_not_found"},
                       500
        end)

      # The slug is logged, because the code the client gets does not carry it.
      assert log =~ "no-such-role"
      assert Agents.list_agents_info_for_space(space_id) == []
    end

    test "a create refusal is passed through with the detail it carries", %{
      socket: socket,
      space_id: space_id
    } do
      # The refusal a manual spawn can really hit is the `"none"`-backend
      # collision, because the name is the operator's: another such space's live
      # agent holds it. `Agents.create_agent/3` is stubbed so the mapping is
      # tested without building two `"none"` spaces (and without the global
      # vocation catalogue those fixtures touch).
      Mimic.stub(Nest.Agents, :create_agent, fn _space, _model, _opts ->
        {:error, {:scratch_name_in_use, "other-space"}}
      end)

      Mimic.allow(Nest.Agents, self(), socket.channel_pid)

      assert_reply push(socket, "spawn_agent", %{"space_id" => space_id, "model" => @model}),
                   :error,
                   %{"reason" => "scratch_name_in_use", "space_name" => "other-space"},
                   500
    end

    test "a create failure it cannot word is logged as a spawn, not a space", %{
      socket: socket,
      space_id: space_id
    } do
      # The shared `create_payload/1` logs "Failed to create space", which is the
      # wrong sentence for a spawn — the operator reading the log has to know
      # which action to look at. A reason no arm words is the case that reaches
      # the fallback.
      Mimic.stub(Nest.Agents, :create_agent, fn _space, _model, _opts -> {:error, :boom} end)
      Mimic.allow(Nest.Agents, self(), socket.channel_pid)

      log =
        capture_log(fn ->
          assert_reply push(socket, "spawn_agent", %{"space_id" => space_id, "model" => @model}),
                       :error,
                       %{"reason" => "failed_to_create"},
                       500
        end)

      assert log =~ "Failed to spawn an agent in space #{space_id}"
    end

    test "a duplicate name is refused, naming the agent that is taken", %{
      socket: socket,
      space_id: space_id
    } do
      name = "dupe-#{System.unique_integer([:positive])}"
      payload = %{"space_id" => space_id, "name" => name, "model" => @model}

      assert_reply push(socket, "spawn_agent", payload), :ok, %{"name" => ^name}, 500
      AgentTestHelpers.ensure_cleanup(name)

      assert_reply push(socket, "spawn_agent", payload),
                   :error,
                   %{"reason" => "duplicate_name", "message" => message},
                   500

      # The create path answers this with its generic `failed_to_create`, whose
      # message is about a space. A spawn knows the name it asked for, so it
      # says which one is taken.
      assert message == "An agent named #{inspect(name)} already exists in this space."
      assert length(Agents.list_agents_info_for_space(space_id)) == 1
    end

    test "a duplicate the client did not choose is answered without naming nil", %{
      socket: socket,
      space_id: space_id
    } do
      # A generated name is free by construction, so this arm is defensive: the
      # create path can still say `duplicate_name`, and the payload named
      # nothing — which is not a name the operator chose, so it must not be
      # reported as "An agent named nil already exists".
      Mimic.stub(Nest.Agents, :create_agent, fn _space, _model, _opts ->
        {:error, :duplicate_name}
      end)

      Mimic.allow(Nest.Agents, self(), socket.channel_pid)

      assert_reply push(socket, "spawn_agent", %{"space_id" => space_id, "model" => @model}),
                   :error,
                   %{
                     "reason" => "duplicate_name",
                     "message" => "Could not find a free name for the new agent; try again."
                   },
                   500
    end

    test "with no vocation to give, the spawn is refused rather than created bare", %{
      socket: socket,
      space_id: space_id
    } do
      # This space has no blueprint and the catalogue is empty: there is no
      # vocation to inherit, and `agents.vocation_id` is NOT NULL — so the
      # answer is the named `missing_vocation`, not a failed create. The
      # catalogue is stubbed empty rather than emptied: the table is shared with
      # every other async test, and deleting it takes their rows (and trips the
      # `agents.vocation_id` FK against any agent they hold).
      Mimic.stub(Nest.Vocations, :list_vocations, fn -> [] end)
      Mimic.allow(Nest.Vocations, self(), socket.channel_pid)

      payload = %{"space_id" => space_id, "model" => @model}

      assert_reply push(socket, "spawn_agent", payload),
                   :error,
                   %{"reason" => "missing_vocation"},
                   500

      assert Agents.list_agents_info_for_space(space_id) == []
    end

    test "a malformed payload is refused", %{socket: socket, space_id: space_id} do
      for payload <- [
            %{"space_id" => "not-an-integer"},
            %{"space_id" => space_id, "name" => 42},
            %{"space_id" => space_id, "vocation" => 42},
            %{"space_id" => space_id, "model" => "qwen3.5-plus"}
          ] do
        assert_reply push(socket, "spawn_agent", payload),
                     :error,
                     %{"reason" => "invalid_payload"},
                     500
      end

      # Not a map at all: the channel's own catch-all answers, which is why the
      # event has one beside the handler that takes a map.
      assert_reply push(socket, "spawn_agent", []),
                   :error,
                   %{"reason" => "invalid_payload"},
                   500
    end
  end

  defp join_as(user) do
    token = Accounts.AuthToken.sign(user.id)
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(connected, LobbyChannel, "lobby")
    socket
  end

  defp info_for(space_id, name) do
    space_id
    |> Agents.list_agents_info_for_space()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> flunk("agent #{name} is not in space #{space_id}'s list")
      info -> info
    end
  end
end

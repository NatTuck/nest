defmodule NestWeb.LobbyChannel.AgentErrorsTest do
  @moduledoc """
  Pins the reply payload `AgentErrors.create_payload/1` builds for each reason
  `Spaces.create_space_with_root_agent/2` can return, and the one tagged reason
  `edit_agent` can carry.

  The create path's reason space is heterogeneous: the refusals a user can act
  on, plus changesets and internal terms from the space insert and the root
  agent spawn. Only the first group can be named in a reply — an
  `Ecto.Changeset` is neither `to_string/1`-able nor fit to show a user — so
  the mapping names what it can and stays generic (and logged) for the rest.
  None of this is reachable from the happy-path channel tests.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.PersistedAgent
  alias Nest.Spaces.Space
  alias NestWeb.LobbyChannel.AgentErrors

  test "names every refusal a user can act on" do
    for {reason, code} <- [
          {:workspace_required, "workspace_required"},
          {:workspace_missing, "workspace_missing"},
          {:workspace_under_tmp, "workspace_under_tmp"},
          {:blueprint_missing, "blueprint_missing"},
          {:missing_vocation, "missing_vocation"}
        ] do
      assert {:error, %{"reason" => ^code}} = AgentErrors.create_payload(reason)
    end
  end

  test "names a config file Nest cannot protect, with its path, on both paths" do
    # `create_payload/1` and `edit_payload/2` both have to name it. Without the
    # edit clause the tuple falls through to `to_string/1`, which raises and
    # kills the channel process — the client gets no reply at all.
    reason = {:config_file_not_regular, "/home/nat/proj/AGENTS.md"}

    assert {:error, %{"reason" => "config_file_not_regular", "path" => path}} =
             AgentErrors.create_payload(reason)

    assert path == "/home/nat/proj/AGENTS.md"

    assert {:error, %{"reason" => "config_file_not_regular", "path" => ^path}} =
             AgentErrors.edit_payload("some-agent", reason)
  end

  test "names a blueprint whose root vocation is gone, and logs the slug" do
    log =
      capture_log(fn ->
        assert {:error, %{"reason" => "vocation_not_found"}} =
                 AgentErrors.create_payload({:vocation_not_found, "ghost-vocation"})
      end)

    assert log =~ "ghost-vocation"
  end

  test "names an unsafe client-supplied root-agent name" do
    changeset =
      PersistedAgent.changeset(%PersistedAgent{}, %{
        name: "Code Reviewer",
        space_id: 1,
        model: %{name: "m", provider: "p"}
      })

    assert {:error, %{"reason" => "invalid_agent_name"}} =
             AgentErrors.create_payload(changeset)
  end

  test "stays generic for a space changeset, whatever field it failed on" do
    # A blank space name — or a slug that could not be the root agent's name —
    # is not an agent-name problem, and the agent's own `data:` match is what
    # keeps the two apart. The slug case is why `Space.changeset/2` validates
    # the slug at all: it used to surface as `invalid_agent_name`, naming a
    # field the client never sent.
    blank_name = Space.changeset(%Space{}, %{name: "", created_by_user_id: 1})

    unusable_slug =
      Space.changeset(%Space{}, %{name: "My Space", slug: "my space", created_by_user_id: 1})

    assert {"must be usable as an agent name (letters, digits, `_` and `-`)", _} =
             unusable_slug.errors[:slug]

    log =
      capture_log(fn ->
        for changeset <- [blank_name, unusable_slug] do
          assert {:error, %{"reason" => "failed_to_create"}} =
                   AgentErrors.create_payload(changeset)
        end
      end)

    assert log =~ "Failed to create space"
  end

  test "stays generic and logs a reason it cannot show a user" do
    # The changeset is the case that makes the generic arm load-bearing:
    # `to_string/1` raises on it, so a raw pass-through would crash the channel.
    changeset = %Ecto.Changeset{errors: [name: {"can't be blank", []}]}

    log =
      capture_log(fn ->
        for reason <- [changeset, :missing_system_prompt, :not_found] do
          assert {:error, %{"reason" => "failed_to_create"}} =
                   AgentErrors.create_payload(reason)
        end
      end)

    assert log =~ "Failed to create space"
  end
end

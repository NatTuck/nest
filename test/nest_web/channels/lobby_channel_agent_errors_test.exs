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
    reason = {:config_file_not_regular, "/home/nat/proj/AGENTS.md", :symlink}

    assert {:error, %{"reason" => "config_file_not_regular", "path" => path, "type" => "symlink"}} =
             AgentErrors.create_payload(reason)

    assert path == "/home/nat/proj/AGENTS.md"

    assert {:error,
            %{"reason" => "config_file_not_regular", "path" => ^path, "type" => "symlink"}} =
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

    assert {"must be usable as an agent name (lowercase letters, digits, `_` and `-`)", _} =
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

  test "answers a tagged reason it has no clause for with the caller's own code" do
    # A tagged reason carries a detail term, so neither path may pass it to
    # `to_string/1` — that raises and kills the channel. The two paths do not
    # share a fallback code either: the client shows the user whether it was
    # creating or editing.
    reason = {:some_new_refusal, "detail"}

    log =
      capture_log(fn ->
        assert {:error, %{"reason" => "failed_to_create"}} = AgentErrors.create_payload(reason)

        assert {:error, %{"reason" => "failed_to_edit"}} =
                 AgentErrors.edit_payload("some-agent", reason)
      end)

    assert log =~ "Failed to create space: {:some_new_refusal, \"detail\"}"
    assert log =~ "Failed to edit agent \"some-agent\": {:some_new_refusal, \"detail\"}"
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

  describe "change_model_payload/2 and edit_payload/2" do
    test "name each refusal the agent edit can produce" do
      for {reason, code} <- [
            {:agent_busy, "agent_busy"},
            {{:invalid_model, "ghost"}, "invalid_model"},
            {:not_found, "not_found"}
          ] do
        assert {:error, %{"reason" => ^code}} = AgentErrors.change_model_payload("a", reason)
      end

      for {reason, code} <- [
            {:agent_busy, "agent_busy"},
            {{:invalid_model, "ghost"}, "invalid_model"},
            {:context_overflow, "context_overflow"},
            {:not_found, "not_found"}
          ] do
        assert {:error, %{"reason" => ^code}} = AgentErrors.edit_payload("a", reason)
      end
    end

    test "log, and stay generic, for a reason neither path can show" do
      log =
        capture_log(fn ->
          # The change-model path answers with the reason's own name here
          # (`ErrorPayload.from_reason/1`), which is a code the client already
          # knows; the edit path has no such arm and falls back to its own.
          assert {:error, %{"reason" => "gen_server_timeout"}} =
                   AgentErrors.change_model_payload("a", :gen_server_timeout)

          assert {:error, %{"reason" => "failed_to_edit"}} =
                   AgentErrors.edit_payload("a", :missing_system_prompt)
        end)

      assert log =~ "Failed to change model on agent \"a\""
      assert log =~ "Failed to edit agent \"a\""
    end
  end

  describe "edit_space_payload/1" do
    test "names every refusal a user can act on" do
      # The same codes the create path produces for the same refusals, because a
      # workspace the sandbox will not run is refused at the edit for exactly the
      # reason it is refused at the create.
      for {reason, code} <- [
            {:workspace_required, "workspace_required"},
            {:workspace_missing, "workspace_missing"},
            {:workspace_under_tmp, "workspace_under_tmp"},
            {:blueprint_missing, "blueprint_missing"},
            {:missing_vocation, "missing_vocation"}
          ] do
        assert {:error, %{"reason" => ^code}} = AgentErrors.edit_space_payload(reason)
      end
    end

    test "names a config file Nest cannot protect, with its path and type" do
      reason = {:config_file_not_regular, "/home/nat/proj/.nest", :symlink}

      assert {:error,
              %{
                "reason" => "config_file_not_regular",
                "path" => "/home/nat/proj/.nest",
                "type" => "symlink"
              }} =
               AgentErrors.edit_space_payload(reason)
    end

    test "names the backend, the one field the changeset validates by value" do
      changeset =
        Space.environment_changeset(
          %Space{workspace_path: "/home/nat/ws"},
          %{sandbox_backend: "firecracker"}
        )

      assert {:error, %{"reason" => "invalid_sandbox_backend"}} =
               AgentErrors.edit_space_payload(changeset)
    end

    test "names a blank workspace, the changeset's other client-facing field" do
      # `environment_changeset/2`'s only `:workspace_path` error is
      # `validate_required`, and `Nest.Sandbox.workspace_error/1` already names that
      # refusal — so the client gets a code it can word, and an ordinary mistake is
      # not logged at `:error`. Not captured: if the generic arm were taken, the
      # suite would print.
      changeset = %Ecto.Changeset{
        data: %Space{},
        errors: [workspace_path: {"can't be blank", [validation: :required]}]
      }

      assert {:error, %{"reason" => "workspace_required"}} =
               AgentErrors.edit_space_payload(changeset)
    end

    test "stays generic, and logs, for a changeset error it cannot show" do
      # A slug collision: not a field the user can fix from the dialog, and an
      # `Ecto.Changeset` is not fit to hand a user.
      changeset = %Ecto.Changeset{
        data: %Space{},
        errors: [slug: {"has already been taken", [constraint: :unique]}]
      }

      log =
        capture_log(fn ->
          assert {:error, %{"reason" => "failed_to_edit"}} =
                   AgentErrors.edit_space_payload(changeset)

          assert {:error, %{"reason" => "failed_to_edit"}} =
                   AgentErrors.edit_space_payload({:some_new_refusal, "detail"})
        end)

      assert log =~ "Failed to edit space"
    end
  end
end

defmodule NestWeb.LobbyChannel.AgentErrorsTest do
  @moduledoc """
  Pins the reply payload `AgentErrors.create_payload/1` builds for each reason
  `Spaces.create_space_with_root_agent/2` can return.

  The create path's reason space is heterogeneous: the refusals a user can act
  on, plus changesets and internal terms from the space insert and the root
  agent spawn. Only the first group can be named in a reply — an
  `Ecto.Changeset` is neither `to_string/1`-able nor fit to show a user — so
  the mapping names what it can and stays generic (and logged) for the rest.
  None of this is reachable from the happy-path channel tests.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  test "names a blueprint whose root vocation is gone, and logs the slug" do
    log =
      capture_log(fn ->
        assert {:error, %{"reason" => "vocation_not_found"}} =
                 AgentErrors.create_payload({:vocation_not_found, "ghost-vocation"})
      end)

    assert log =~ "ghost-vocation"
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

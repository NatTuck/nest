defmodule NestWeb.AgentChannelArchivedTest do
  @moduledoc """
  `NestWeb.AgentChannel`'s refusal to bring an *archived* agent back.

  Archiving stops the agent and marks its row archived. Nothing may
  start it again by accident — not a chat-URL join, and not a message
  from a channel that was already connected when the agent was
  archived. Otherwise the sidebar shows the agent under Archived while
  `agents-list` reports it live.

  Split from `NestWeb.AgentChannelTest` to keep that file inside the
  credo file-length budget.
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Persistence

  setup :verify_on_exit!

  describe "join/3 for an archived agent" do
    test "returns agent_archived instead of resurrecting it", %{user: user, space_id: space_id} do
      # The archived agent has no live process, so the join goes through
      # the on-demand load path — which must refuse to start it.
      name = "archived-join-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: %{"name" => "qwen3.5-plus", "provider" => "model-studio"},
          vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
          created_by_user_id: user.id
        })

      assert :ok = Persistence.archive_agent(space_id, name)

      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      assert {:error, %{"reason" => "agent_archived"}} =
               subscribe_and_join(connected, AgentChannel, "agent:#{space_id}:#{name}")

      # The refusal leaves no process behind: the row exists and is archived, so
      # a join that started it would make `agents-list` report it live while the
      # sidebar still files it under Archived.
      assert {:error, :not_found} = Nest.Agents.Registry.lookup(space_id, name)
    end
  end
end

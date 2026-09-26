defmodule NestWeb.AgentChannelNeedsRepairTest do
  @moduledoc """
  Channel coverage for the `:needs_repair` on-load state: the `init`
  payload carries the violations + repair command, and `chat:message`
  is refused with `agent_status_needs_repair`.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence

  test "init carries the violations and chat:message is refused", %{
    user: user,
    space_id: space_id
  } do
    name = "needs-repair-channel-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: nil,
        vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
        created_by_user_id: user.id
      })

    for message <- [system(0), user(1, "run"), assistant_tool(2, "call_1")] do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end

    {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, _pid} = Supervisor.start_under_test(attrs)
    end)

    token = Process.get(:agent_test_token)
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

    # The helper setup already joined its own agent and left an `init`
    # push for it in the test mailbox; consume it so the next push is
    # the needs_repair agent's.
    assert_push "init", _helper_init

    {:ok, _, socket} =
      subscribe_and_join(connected, NestWeb.AgentChannel, "agent:#{space_id}:#{name}")

    assert_push "init", init
    assert init["status"] == "needs_repair"
    assert [%{rule: :no_trailing_orphan}] = init["sequenceViolations"]
    assert init["repairCommand"] =~ "mix nest.repair_messages --space "

    ref = push(socket, "chat:message", %{"content" => "hello?"})
    assert_reply ref, :error, %{"reason" => "agent_status_needs_repair"}
  end

  # ---- helpers ----

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index, text), do: {:user, %User{index: index, parts: [%Part.Text{text: text}]}}

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end
end

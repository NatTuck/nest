defmodule Nest.Agents.AgentOverflowIntegrationTest do
  @moduledoc """
  Integration test for the Overflow error path.

  Before this fix, `Overflow.system_size/1` looked at
  `state.chat_state.messages[0]` and fell back to the
  whole-list size when no `{:system, _}` was at index 0.
  The live session reported "~85504 tokens" for the system
  prompt — but 85k was the entire conversation size, not
  the actual system content.

  This test simulates that drift (drops the system from
  `messages[0]` via `:sys.replace_state`) and verifies the
  Overflow message now reports the rendered system size
  from `compose_vocation_config/4`, not the conversation
  total.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.Compaction.Overflow
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Vocations

  # conflicts with our private helper below
  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  # Helper: render the system prompt the way production does
  # and return (size_in_tokens, rendered_string).
  defp render_for(state) do
    {system_prompt, _, _, _} =
      SystemPrompt.compose_vocation_config(
        state.vocation,
        state.workspace_path,
        {state.llm_metrics.context_limit, state.llm_metrics.context_limit_source},
        state.depth
      )

    {Overflow.system_size(system_prompt), system_prompt}
  end

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    :ok
  end

  defp create_vocation(attrs) do
    merged =
      Map.merge(
        %{
          name: "Overflow-Integration-#{System.unique_integer([:positive])}",
          description: "Overflow integration test",
          system_prompt: "Overflow-marked-prompt-#{System.unique_integer([:positive])}",
          tools: ["context"],
          modes: %{
            "chat" => %{
              "description" => "General conversation.",
              "caps" => %{
                "net" => false,
                "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
              }
            }
          }
        },
        attrs
      )

    {:ok, %Vocations.Vocation{} = vocation} = Vocations.create_vocation(merged)
    vocation
  end

  # Simulate the drift: the agent's `messages[0]` is something
  # other than `{:system, _}` (mirrors the live-session bug).
  # We replace the system with a large user message so the
  # whole-list "fallback" estimate would inflate hugely.
  defp drift_messages_to_no_system(pid) do
    :sys.replace_state(pid, fn state ->
      drift_text = String.duplicate("drift ", 50_000)

      drifted =
        state.chat_state.messages
        |> List.delete_at(0)
        |> Kernel.++([
          {:user, %User{index: 1, parts: [%Part.Text{text: drift_text}], api_logs: []}}
        ])

      %{state | chat_state: %{state.chat_state | messages: drifted}}
    end)
  end

  describe "Overflow.message/4 uses rendered size, not messages[0] fallback" do
    test "reports the rendered prompt size when messages[0] has no system" do
      vocation = create_vocation(%{})
      {pid, _agent_id} = start_agent(%{vocation_id: vocation.id, vocation: vocation})

      drift_messages_to_no_system(pid)
      state = :sys.get_state(pid)

      refute match?({:system, _}, Enum.at(state.chat_state.messages, 0))

      {rendered_size, system_prompt} = render_for(state)

      refute rendered_size == 0

      msg = Overflow.message(state.llm_metrics.context_limit, system_prompt, "compact")
      assert msg =~ "system prompt (~#{rendered_size} tokens)"
    end

    test "reports the rendered prompt size for :system_oversized even with drift" do
      vocation = create_vocation(%{})
      {pid, _agent_id} = start_agent(%{vocation_id: vocation.id, vocation: vocation})

      drift_messages_to_no_system(pid)
      state = :sys.get_state(pid)

      {rendered_size, system_prompt} = render_for(state)

      msg =
        Overflow.message(
          state.llm_metrics.context_limit,
          system_prompt,
          "compact",
          :system_oversized
        )

      assert msg =~ "system prompt is ~#{rendered_size} tokens"
      assert msg =~ "25% safety budget"
    end
  end

  describe "messages[0] drift does NOT inflate the Overflow size" do
    test "the rendered size is independent of state.chat_state.messages contents" do
      vocation = create_vocation(%{})
      {pid, _agent_id} = start_agent(%{vocation_id: vocation.id, vocation: vocation})

      state = :sys.get_state(pid)
      {before, _} = render_for(state)

      drift_messages_to_no_system(pid)
      drifted_state = :sys.get_state(pid)
      {after_drift, _} = render_for(drifted_state)

      assert before == after_drift,
             "Overflow.system_size should depend on rendered prompt, not messages[0]"
    end
  end
end

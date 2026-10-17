defmodule Nest.Agents.AgentSpawnDepthPromptTest do
  @moduledoc """
  The spawn-depth line in an agent's own system message.

  `SystemPrompt.compose_vocation_config/5`'s last two arguments are `depth` and
  `mode` — both short, adjacent, and easy to transpose — and transposing them
  renders `You are at spawn depth act of 3` into every prompt the start path
  composes, and authorizes the `AGENTS.md` read with the wrong mode's caps.

  The unit tests call the composer directly, so they cannot see a *caller* that
  passes its arguments in the wrong order; this goes through the **start path**,
  which is the only caller that matters. It is the assertion that would have
  caught the transposition when part A's `compose_vocation_config/5` met part B's
  call site.
  """

  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTestHelpers

  alias Nest.Agents.Agent.Config
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "a started agent's system message names its real spawn depth, not its mode" do
    workspace = default_test_workspace()

    {pid, _agent_id} =
      start_agent(%{model: %{name: "qwen3.5-plus"}, workspace_path: workspace})

    # allowlist: snapshot — the system message the *start path* composed, which is
    # the thing under test; nothing else exposes the composed prompt.
    [{:system, system} | _rest] = :sys.get_state(pid).chat_state.messages

    text = system.parts |> Enum.map_join("\n", & &1.text)

    assert text =~ "at spawn depth 0 of #{Config.configured_max_depth()}"

    # The transposition's signature: the mode where the depth belongs. Both
    # directions, so a future swap of *either* argument is caught.
    refute text =~ "spawn depth act"
    refute text =~ "spawn depth plan"
  end
end

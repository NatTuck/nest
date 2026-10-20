defmodule Nest.Agents.Agent.SystemPromptCacheTest do
  @moduledoc """
  The system message is prefix-cache-visible, so an unchanged session must render
  it byte-for-byte the same at every composition point.

  It is composed at start (`Nest.Agents.Agent.Init`) and re-composed on every
  compaction (`Nest.Agents.Agent.Turn.Dispatch`'s plan, and the commit that
  replaces the system row) — from a different source of the same fact each time:
  the row's model name at start, `client_config.model` in the turn context. This
  pins that the re-render reproduces the prompt it replaced, the model section
  among it, so a call site that passed a different (or no) model name — or a
  section built from something volatile — fails here instead of quietly costing
  the cache.
  """
  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTestHelpers

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "a compaction re-renders the prompt byte-for-byte, model section included" do
    vocation_id = programmer_vocation_id_for_test()

    {pid, _agent_id} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    prompt_before = get_system_prompt(pid)

    # The manual `/compact`: the compaction stages, the compactor answers, the
    # commit replaces the system row with a freshly rendered one.
    :ok = Agent.compact(pid, nil)
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    prompt_after = get_system_prompt(pid)

    # The same facts, so the same bytes — and the model section is one of them.
    assert prompt_after == prompt_before
  end
end

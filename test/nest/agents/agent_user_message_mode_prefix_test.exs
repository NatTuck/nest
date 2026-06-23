defmodule Nest.Agents.AgentUserMessageModePrefixTest do
  @moduledoc """
  Dedicated tests for the user-message `[mode: <name>]\n` content
  prefix. The prefix is an intentional, load-bearing design choice
  — see the `INTENTIONAL` comment block on the test below for the
  full rationale.

  This test lives in its own file (rather than in
  `agent_chat_test.exs`) so the design intent is discoverable from
  the file name, and so a future regression that drops the prefix
  fails this single, clearly-flagged test instead of being lost
  among unrelated chat tests.
  """
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Test.TaskDrain

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  # INTENTIONAL: the user message's `content` is intentionally
  # prefixed with `[mode: <effective_mode>]\n` before it is
  # persisted / broadcast.
  #
  # This is a core design choice — DO NOT REMOVE the prefix.
  # Reasons:
  #
  #   1. The LLM is the primary consumer of the user message
  #      content. The mode prefix is how the model sees the
  #      mode the user is in for that turn. Without the prefix,
  #      the model would have to infer the mode from a separate
  #      side channel (or a system-prompt-only field) and the
  #      turn-by-turn signal would be lost as the conversation
  #      grows.
  #
  #   2. The prefix round-trips through any persistence layer
  #      (broadcast, history, replay, log). If a future change
  #      adds a turn-by-turn mode replay feature, the prefix is
  #      the source of truth — `metadata.mode` is the fast path
  #      for the UI, the prefix is the durable path.
  #
  #   3. The chat UI strips the prefix on render (see
  #      `assets/js/utils/stripModePrefix.js`) because the mode
  #      badge already shows the mode. The two encodings
  #      (`metadata.mode` and the `content` prefix) MUST agree.
  #
  # If you are changing this test, you are almost certainly
  # breaking the design. Talk to the team first.
  test "user message content is prefixed with the effective mode (intentional design choice)" do
    {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

    # No mode argument -> defaults to "chat" (vocation-less agent).
    :ok = Agent.chat(pid, "Hello world")

    assert_receive {:chat_message,
                    {:user,
                     %{content: "[mode: chat]\nHello world", metadata: %{"mode" => "chat"}}}},
                   100
  end
end

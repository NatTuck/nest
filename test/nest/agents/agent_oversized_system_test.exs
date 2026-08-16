defmodule Nest.Agents.AgentOversizedSystemTest do
  @moduledoc """
  Tests for the 25% safety budget on the rendered system prompt.

  The Trigger checks `SystemPrompt.within_size_budget?/2` before
  computing the summary budget. If the rendered prompt exceeds 25%
  of the context window, compaction refuses with the
  `:system_oversized` error wording instead of the generic
  `:reserve_exhausted` one.

  Companion tests:
  - `system_prompt_size_budget_test.exs` — unit tests for the
    `within_size_budget?/2` helper.
  - `agent_overflow_integration_test.exs` — verifies the
    message uses the rendered size, not the messages[0] fallback.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.Compaction.Trigger
  alias Nest.LLM.MockClient
  alias Nest.Vocations

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1, vocation_id_for_test: 0]

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
          name: "Oversized-#{System.unique_integer([:positive])}",
          description: "Oversized system test",
          system_prompt: "Original-small-prompt",
          tools: ["context-check", "context-compact"],
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

  # A vocation whose rendered prompt is well over 25% of a
  # compact 8_000-token context (2_000-token budget). 24_000
  # chars of text saturates far past that, but stays small
  # enough that String.duplicate + SystemPrompt.compose are
  # fast.
  @oversized_budget_chars 24_000

  defp oversized_vocation do
    create_vocation(%{
      system_prompt: String.duplicate("x", @oversized_budget_chars)
    })
  end

  defp normal_vocation do
    create_vocation(%{})
  end

  defp agent_state(pid), do: :sys.get_state(pid)

  # Build a minimal state struct for `Trigger.post_turn/1` tests.
  # `Trigger.post_turn/1` is a regular function that reads only
  # `state.name`, `state.vocation`, `state.workspace_path`,
  # `state.depth`, `state.llm_metrics`, and `state.live.status`.
  # Spawning a real Agent is ~100ms overhead per test; building
  # the struct directly is <5ms. The test verifies the in-memory
  # state shape + PubSub broadcast, not the GenServer lifecycle.
  #
  # The context_limit defaults to 8_000 so the 24k-char rendered
  # prompt on the oversized vocation exceeds 25% — qwen3.5-plus
  # advertises 512k which is too large to overflow on a small
  # test string.
  defp build_minimal_state(vocation, context_limit \\ 8_000) do
    %Nest.Agents.Agent{
      name: "test-agent-#{System.unique_integer([:positive])}",
      vocation: vocation,
      vocation_id: vocation.id,
      workspace_path: nil,
      depth: 0,
      llm_metrics: %Nest.Agents.Agent.LlmMetrics{
        context_limit: context_limit,
        context_limit_source: :config,
        usage_totals: empty_usage_totals(),
        descendant_usage: empty_usage_totals()
      },
      live: %Nest.Agents.Agent.ChatState.Live{
        status: :idle
      }
    }
  end

  defp empty_usage_totals do
    %{
      input_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_creation_total_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0,
      context_input_tokens: 0
    }
  end

  describe "Trigger.start refuses compaction when the rendered system exceeds 25% budget" do
    test "the agent transitions to :context_overflow and stays there" do
      vocation = oversized_vocation()

      # Build a minimal state struct (no Agent process) — `Trigger.post_turn/1`
      # is a regular function that only reads `state.name`,
      # `state.vocation`, `state.workspace_path`, `state.depth`,
      # `state.llm_metrics`, and `state.live.status`.
      # Spawning a real Agent is ~100ms overhead per test;
      # building the struct directly is <5ms. The test verifies
      # the in-memory state shape, not the GenServer lifecycle.
      state_before = build_minimal_state(vocation)
      refute state_before.live.status == :context_overflow

      # `Trigger.post_turn/1` → `broadcast_oversized/2` → `Overflow.broadcast/5`
      # → `Broadcasts.error/4` which calls `Logger.error/2`. AGENTS.md
      # line 84-92 forbids tests from printing to the console;
      # `with_log/2` captures the log AND returns the function's
      # result so we can assert the in-memory state shape.
      {state_after, _log} =
        with_log(fn ->
          Trigger.post_turn(state_before)
        end)

      assert state_after.live.status == :context_overflow
    end

    test "the broadcast carries the oversized-system wording" do
      vocation = oversized_vocation()
      state = build_minimal_state(vocation)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      # Capture the Logger.error that the broadcast path emits; the
      # test asserts the PubSub broadcast content separately, so the
      # log is just noise.
      _ = capture_log(fn -> Trigger.post_turn(state) end)

      assert_receive {:chat_error, %{content: msg}}

      assert msg =~ "Cannot compact:"
      assert msg =~ "25% safety budget"
      assert msg =~ "8000-token context"

      refute msg =~ "reserved response budget",
             "oversized path should not use the reserve_exhausted wording"
    end

    test "no compaction chat turn is spawned" do
      vocation = oversized_vocation()
      state = build_minimal_state(vocation)

      {state_after, _log} = with_log(fn -> Trigger.post_turn(state) end)

      assert state_after.live.status == :context_overflow

      assert state_after.live.chat_turn_pid == state.live.chat_turn_pid,
             "Trigger.post_turn should not have spawned a chat turn for an oversized system"
    end
  end

  describe "Trigger.start still works for normal (under-budget) vocations" do
    test "does not refuse when the rendered prompt is within 25%" do
      vocation = normal_vocation()

      # Use a realistic context_limit (above the 8192 response
      # reserve floor). The 8_000 default used by the oversized
      # tests is below the reserve floor, which makes `check_messages`
      # report `:cannot_compact` for ANY message list (reserve alone
      # exceeds the window) and would wrongly trip the pre-flight
      # choke point when the Trigger appends its compaction suffix.
      state_before = build_minimal_state(vocation, 100_000)

      {state_after, _log} = with_log(fn -> Trigger.post_turn(state_before) end)

      # A normal vocation should NOT trigger the oversized path —
      # agent should NOT have transitioned to :context_overflow
      # (whether or not the summary budget check refuses on its
      # own — that's a different code path).
      assert state_after.live.status != :context_overflow or
               state_after.live.status == :compacting
    end
  end

  describe "vocation with no system_prompt (state.vocation == nil)" do
    test "Trigger.start falls back to messages[0] for the rendered size (legacy test fixtures)" do
      # `agents.vocation_id` is a NOT NULL FK, so we have to
      # pass a real id (a "Test Default" vocation inserted by
      # the helper). But `vocation: nil` on the attrs still
      # leaves `state.vocation` as nil after init — the
      # helper only loads the struct into the attrs when
      # `vocation_id` is a non-zero integer AND the helper
      # wants the struct. Here we override `vocation: nil`
      # explicitly to exercise the `compose_vocation_config/4`
      # nil-vocation clause. Trigger's `render_system_prompt/2`
      # falls back to extracting the rendered text from
      # `messages[0]` so the compaction can still proceed
      # (preserves the pre-fix behavior for tests that relied
      # on it).
      vid = vocation_id_for_test()
      {pid, _agent_id} = start_agent(%{vocation_id: vid, vocation: nil})

      state = agent_state(pid)

      # `start_agent/1` ran `Trigger.start/2` already (via
      # `ChatPipeline.handle_chat/3`'s spawn-compaction path),
      # which can broadcast a `chat:error` for the nil-vocation
      # case. Capture so the test output stays clean.
      {state_after, _log} = with_log(fn -> Trigger.post_turn(state) end)

      assert state_after.live.status == :compacting,
             "expected :compacting, got #{inspect(state_after.live.status)}"
    end
  end
end

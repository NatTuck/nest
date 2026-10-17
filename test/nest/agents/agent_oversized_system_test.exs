defmodule Nest.Agents.AgentOversizedSystemTest do
  @moduledoc """
  Tests for the 25% safety budget on the rendered system prompt.

  `Machine.Compaction.stage/2` checks `SystemPrompt.within_size_budget?/2`
  before computing the summary budget. If the rendered prompt exceeds 25%
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
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.Executor
  alias Nest.LLM.MockClient
  alias Nest.TextFixtures
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
          tools: ["context"]
        },
        attrs
      )

    {:ok, %Vocations.Vocation{} = vocation} = Vocations.create_vocation(merged)
    vocation
  end

  # A vocation whose rendered prompt is well over 25% of a
  # compact 8_000-token context (2_000-token budget). 24_000
  # bytes of realistic text saturates far past that and
  # tokenizes linearly.
  @oversized_budget_chars 24_000

  defp oversized_vocation do
    create_vocation(%{
      system_prompt: TextFixtures.big_text(@oversized_budget_chars)
    })
  end

  defp normal_vocation do
    create_vocation(%{})
  end

  # allowlist: harness — Compaction.stage/2 + Executor.run_all/2 drive on the struct
  defp agent_state(pid), do: :sys.get_state(pid, 1_000)

  # The post-turn compaction entry point: stage a compaction against an
  # idle machine via the same pure `Compaction.stage/2` the machine uses.
  # The HTTP spawn is deferred via the mailbox, so a non-GenServer test
  # process never performs a real call.
  defp post_turn(state) do
    ctx = Turn.build_ctx(state)
    machine = %{state.live.machine | work: %{state.live.machine.work | ctx: ctx}}
    {:ok, actions, machine} = Compaction.stage(machine, nil)
    state = %{state | live: %{state.live | machine: machine}}
    {state, _follow} = Executor.run_all(actions, state)
    state
  end

  # Build a minimal state struct for the `Compaction.stage/2` tests.
  # Staging reads `state.live.machine`, `state.llm_metrics`, and the turn
  # context (`Turn.build_ctx/1`). Spawning a real Agent is ~100ms
  # overhead per test; building the struct directly is <5ms. The test
  # verifies the in-memory state shape + PubSub broadcast, not the
  # GenServer lifecycle.
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
      depth: 0,
      llm_metrics: %Nest.Agents.Agent.LlmMetrics{
        context_limit: context_limit,
        context_limit_source: :config,
        usage_totals: empty_usage_totals(),
        descendant_usage: empty_usage_totals()
      },
      live: %Nest.Agents.Agent.ChatState.Live{
        machine: %Machine{}
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

  describe "Compaction staging refuses compaction when the rendered system exceeds 25% budget" do
    test "the agent transitions to :context_overflow and spawns no chat worker" do
      # Two observables of one outcome, so one test. From the first name: the
      # agent lands in `:context_overflow` and stays there — it does not fall
      # back to idle, and no turn is started for it. From the second: the
      # oversized path spawns no chat worker, because the refusal happens before
      # any compaction request is dispatched.
      vocation = oversized_vocation()

      # Build a minimal state struct (no Agent process): `Compaction.stage/2`
      # reads only `state.live.machine` and the turn context. Spawning a
      # real Agent is ~100ms overhead per test; building the struct
      # directly is <5ms. The test verifies the in-memory state shape,
      # not the GenServer lifecycle.
      state_before = build_minimal_state(vocation)
      refute Machine.status_for(state_before.live.machine) == :context_overflow

      # The `{:overflow, :system_oversized, _}` broadcast → `Overflow.broadcast/5`
      # → `Broadcasts.error/4`, which logs the wording and broadcasts the same
      # text. The log is captured *and asserted* — a capture nobody asserts on
      # can only hide prints (`SMELLS.md`) — and `with_log/2` returns the
      # function's result, so the state shape is asserted too.
      {state_after, log} = with_log(fn -> post_turn(state_before) end)

      assert Machine.status_for(state_after.live.machine) == :context_overflow

      assert is_nil(state_after.live.machine.work.active_worker),
             "the oversized-system path must not have spawned a chat worker"

      assert log =~ "chat:error"
      assert log =~ "Cannot compact:"
      assert log =~ "25% safety budget"
      assert log =~ "source=Turn.Executor"
    end

    test "the broadcast carries the oversized-system wording" do
      vocation = oversized_vocation()
      state = build_minimal_state(vocation)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      # `Broadcasts.error/4` logs the wording and broadcasts the same text, so
      # the capture is asserted rather than merely silencing, and the broadcast
      # below is the other observable (the one the UI sees).
      log = capture_log(fn -> post_turn(state) end)

      assert_receive {:chat_error, %{content: msg}}

      assert msg =~ "Cannot compact:"
      assert msg =~ "25% safety budget"
      assert msg =~ "8000-token context"

      refute msg =~ "compaction reserve",
             "oversized path should not use the reserve_exhausted wording"

      # The frame and the log line carry the same wording, and each names the
      # call site its own way: the broadcast appends a `[Source: …]` tag, the
      # log line records `source=`.
      assert msg =~ "[Source: Turn.Executor]"
      assert log =~ "Cannot compact:"
      assert log =~ "source=Turn.Executor"
    end
  end

  describe "Compaction staging still works for normal (under-budget) vocations" do
    test "does not refuse when the rendered prompt is within 25%" do
      vocation = normal_vocation()

      # Use a realistic context_limit (above the 8192 response
      # reserve floor). The 8_000 default used by the oversized
      # tests is below the reserve floor, which makes `check_messages`
      # report `:cannot_compact` for ANY message list (reserve alone
      # exceeds the window) and would wrongly trip the pre-flight
      # choke point when compaction staging appends its request suffix.
      state_before = build_minimal_state(vocation, 100_000)

      # No capture: staging a compaction for an under-budget vocation logs
      # nothing, and a capture nobody asserts on can only hide prints
      # (`SMELLS.md`), so the one that used to sit here is gone.
      state_after = post_turn(state_before)

      # A normal vocation should NOT trigger the oversized path —
      # agent should NOT have transitioned to :context_overflow
      # (whether or not the summary budget check refuses on its
      # own — that's a different code path).
      assert Machine.status_for(state_after.live.machine) != :context_overflow or
               Machine.status_for(state_after.live.machine) == :compacting
    end
  end

  describe "vocation with no system_prompt (state.vocation == nil)" do
    test "Compaction staging falls back to messages[0] for the rendered size (legacy test fixtures)" do
      # `agents.vocation_id` is a NOT NULL FK, so we have to
      # pass a real id (a "Test Default" vocation inserted by
      # the helper). But `vocation: nil` on the attrs still
      # leaves `state.vocation` as nil after init — the
      # helper only loads the struct into the attrs when
      # `vocation_id` is a non-zero integer AND the helper
      # wants the struct. Here we override `vocation: nil`
      # explicitly to exercise the `compose_vocation_config/6`
      # nil-vocation clause. `Dispatch.compaction_plan/1`'s
      # `system_prompt/2` falls back to extracting the rendered text
      # from `messages[0]` so the compaction can still proceed
      # (preserves the pre-fix behavior for tests that relied
      # on it).
      vid = vocation_id_for_test()
      {pid, _agent_id} = start_agent(%{vocation_id: vid, vocation: nil})

      state = agent_state(pid)

      # No capture: the nil-vocation fallback stages the compaction without
      # logging, so there is no line to assert and nothing to hide — the
      # defensive capture that used to sit here is gone (`SMELLS.md`).
      state_after = post_turn(state)

      assert Machine.status_for(state_after.live.machine) == :compacting,
             "expected :compacting, got #{inspect(Machine.status_for(state_after.live.machine))}"
    end
  end
end

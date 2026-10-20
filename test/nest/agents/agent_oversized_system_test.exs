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

  # The post-turn compaction entry point: stage a compaction against an
  # idle machine via the same pure `Compaction.stage/2` the machine uses,
  # then run its actions. On the refusal path those are a broadcast and a
  # transcript append only, so no worker is started.
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
      # A real agent always has one (`Init` resolves it before the prompt is
      # composed, and the prompt states its model), so a fixture without one is
      # not a state the runtime can reach.
      client_config: %Nest.LLM.ClientConfig{client: MockClient, model: "qwen3.5-plus"},
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
    test "the agent blocks in :context_overflow, spawns no chat worker, and broadcasts the oversized wording" do
      # One outcome, three observables: the phase it blocks in, the worker it
      # must not have spawned, and the frame a connected UI receives. The
      # server-side log line is the fourth, asserted for its call site below.
      #
      # The under-budget arm of the same check is `within_size_budget?/2`'s own
      # contract (`system_prompt_size_budget_test.exs`), and staging a
      # compaction that fits is pinned in `machine_compaction_test.exs` (the
      # notice tests, which stage with a `nil` vocation through the
      # `messages[0]` fallback) and end to end in `agent_compaction_test.exs`.
      # The oversized arm's notice row and its `:context_overflow` phase are
      # pinned in `machine_compaction_test.exs`.
      vocation = oversized_vocation()
      state_before = build_minimal_state(vocation)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state_before.space_id}:#{state_before.name}")

      # The `{:overflow, :system_oversized, _}` broadcast → `Overflow.broadcast/5`
      # → `Broadcasts.error/4`, which logs the wording and broadcasts the same
      # text. The log is captured *and asserted* — a capture nobody asserts on
      # can only hide prints (`SMELLS.md`) — and `with_log/2` returns the
      # function's result, so the state shape is asserted too.
      {state_after, log} = with_log(fn -> post_turn(state_before) end)

      assert Machine.status_for(state_after.live.machine) == :context_overflow

      # The interesting claim of a refusal is that nothing happened: the
      # oversized path must not have started a chat worker.
      assert is_nil(state_after.live.machine.work.active_worker),
             "the oversized-system path must not have spawned a chat worker"

      assert_receive {:chat_error, %{content: msg}}

      # This arm's own wording. The shared `"Cannot compact:"` prefix and the
      # `:reserve_exhausted` wording are `compaction/overflow_test.exs`'s, and
      # the rendered size in the same sentence is
      # `agent_overflow_integration_test.exs`'s.
      assert msg =~ "25% safety budget"

      # The state's own context limit is the one interpolated (the budget is a
      # quarter of it), so a caller passing the budget or the reserve instead
      # fails here.
      assert msg =~ "8000-token context"

      # The call site is `Turn.Executor`'s `{:overflow, …}` clause, and this is
      # the only test that pins it for this arm. The `[Source: …]` tag on the
      # broadcast is appended from the same argument (so a nil source would fail
      # here too) and its formatting is `broadcasts_test.exs`'s.
      assert log =~ "source=Turn.Executor"
    end
  end
end

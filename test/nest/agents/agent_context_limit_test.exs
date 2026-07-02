defmodule Nest.Agents.AgentContextLimitTest do
  @moduledoc """
  Tests for the Agent's context-limit resolution at init.

  These tests stub `Nest.Models.context_limit/2` (rather than
  `Req.get/2`) since the per-agent async probe has been
  consolidated into the `Nest.Models` cache. They use
  `Mimic.expect/3` against `Nest.Models` so the call inside
  `Init.initial_context_limit/1` is intercepted. Cannot
  run as `async: true` — Mimic stubs are per-test-process
  by default and the agent's `init/1` runs in a child of
  the test process.
  """

  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Models

  setup :set_mimic_global
  setup :verify_on_exit!

  defp start_probe_agent(attrs) do
    agent_name = "probe-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      name: agent_name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Agent, attrs})

    # The cache lookup happens during the agent's `init/1`. The
    # test process owns the Mimic stub (set in each test), and
    # the stub applies globally (see `set_mimic_global` in
    # `setup`) so the agent's `init/1` sees it without an
    # explicit `Mimic.allow/3`.
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: MockClient}}
    end)

    MockClient.start_link(pid)

    on_exit(fn -> MockClient.stop(pid) end)

    {pid, agent_name}
  end

  test "uses the cached discovered context-limit when no config value is set" do
    test_pid = self()

    Mimic.expect(Models, :context_limit, fn _provider, model_name ->
      send(test_pid, {:cache_lookup, model_name})
      {:openrouter, 200_000}
    end)

    agent_name = "probe-anthropic-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "claude-3-opus-20240229"}
      })

    state = :sys.get_state(pid)
    assert state.llm_metrics.context_limit == 200_000
    assert state.llm_metrics.context_limit_source == :openrouter
    assert_received {:cache_lookup, "claude-3-opus-20240229"}

    Agent.terminate(pid)
  end

  test "handles a `nil` cache hit (model not in /models response)" do
    Mimic.expect(Models, :context_limit, fn _provider, _model ->
      nil
    end)

    {pid, _agent_name} =
      start_probe_agent(%{
        name: "probe-missing-#{System.unique_integer([:positive])}",
        model: %{name: "claude-3-opus-20240229"}
      })

    state = :sys.get_state(pid)
    assert state.llm_metrics.context_limit == nil
    assert state.llm_metrics.context_limit_source == nil

    Agent.terminate(pid)
  end
end

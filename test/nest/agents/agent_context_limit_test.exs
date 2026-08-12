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
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Models

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    :ok
  end

  defp start_probe_agent(attrs) do
    agent_name = "probe-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      name: agent_name,
      space_id: AgentTestHelpers.current_space_id(),
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: AgentTestHelpers.vocation_id_for_test()
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

  test "uses the provider's `default-context-limit` when per-model config and cache are both nil" do
    # `[providers.pegasus]` in `test/data/config.toml` has
    # `default-context-limit = 512000` but no static entry for the
    # test model name, so per-model returns nil. The cache
    # stub returns nil. The provider default kicks in.
    Mimic.expect(Models, :context_limit, fn _provider, _model ->
      nil
    end)

    agent_name = "probe-provider-default-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "pegasus-default-only", provider: "pegasus"}
      })

    state = :sys.get_state(pid)
    assert state.llm_metrics.context_limit == 512_000
    assert state.llm_metrics.context_limit_source == :provider_default

    Agent.terminate(pid)
  end

  test "per-model `context-limit` wins over provider-level `default-context-limit`" do
    # `pegasus-per-model-test` is a static-config entry under
    # `[providers.pegasus]` with `context-limit = 32000`. The
    # same provider has `default-context-limit = 512000`. The
    # per-model value wins per the resolution precedence.
    #
    # No `Models.context_limit/2` stub here: the per-model hit
    # short-circuits the resolution chain, so the cache closure
    # is captured but never invoked.
    agent_name = "probe-per-model-wins-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "pegasus-per-model-test", provider: "pegasus"}
      })

    state = :sys.get_state(pid)
    assert state.llm_metrics.context_limit == 32_000
    assert state.llm_metrics.context_limit_source == :config

    Agent.terminate(pid)
  end

  test "propagates an Olla-extracted context-limit from the cache" do
    # The typhon /olla gateway returns `max_context_length` under
    # the `olla` namespace rather than at the model root, which
    # Discover now extracts as `{:olla, N}`. This pins the full
    # chain: Discover → Nest.Models cache → Init.initial_context_limit
    # → Agent.llm_metrics. Without the Olla branch, this case
    # would fall through to provider default and (with the typhon
    # provider not configured in test/data/config.toml) end up
    # with `context_limit: nil`.
    test_pid = self()

    Models
    |> stub(:context_limit, fn _provider, _model_name ->
      send(test_pid, {:cache_lookup, "typhon"})
      {:olla, 224_000}
    end)

    # Stub `create_client_config` so the agent starts despite
    # the typhon provider not being in test/data/config.toml.
    # The model-resolution side-effect is what we care about.
    Nest.Agents.Agent.Config
    |> stub(:create_client_config, fn _model ->
      {:ok,
       %Nest.LLM.ClientConfig{
         client: Nest.LLM.OpenAIClient,
         base_url: "http://typhon:4040/olla",
         api_key: "none",
         model: "Qwen/Qwen3.6-27B-FP8",
         receive_timeout: 5000
       }}
    end)

    agent_name = "probe-olla-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "Qwen/Qwen3.6-27B-FP8", provider: "typhon"}
      })

    state = :sys.get_state(pid)
    assert state.llm_metrics.context_limit == 224_000
    assert state.llm_metrics.context_limit_source == :olla
    assert_received {:cache_lookup, "typhon"}

    Agent.terminate(pid)
  end
end

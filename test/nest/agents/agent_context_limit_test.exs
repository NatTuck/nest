defmodule Nest.Agents.AgentContextLimitTest do
  @moduledoc """
  Tests for the Agent's context-limit resolution at init.

  The cache tier of `Init.initial_context_limit/2` is injected
  through the `:context_limit_lookup` attr (see `start_probe_agent/1`)
  rather than stubbed globally. The lookup runs inside the agent's
  `init/1` process, which the supervisor spawned and which therefore
  has no `$callers` chain back to the test pid, so a per-test stub
  would not be visible to it. The injected closure runs in that child
  process and messages the test pid, so each test can assert both the
  resolved limit and that the lookup actually ran.

  Runs `async: true`: the DB work (`create_test_space/0`,
  `vocation_id_for_test/0`) happens in the test pid's own sandboxed
  transaction, agent names / space ids / MockClient names are
  per-test unique, and `Init.build_state/2` plus `Agent.terminate/2`
  do no DB work.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

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

    # The injected `:context_limit_lookup` closure runs inside the
    # agent's `init/1` process and messages the test pid; no stub is
    # set globally.
    :sys.replace_state(
      pid,
      fn state -> %{state | client_config: %{state.client_config | client: MockClient}} end,
      1_000
    )

    MockClient.start_link(pid)

    on_exit(fn -> MockClient.stop(pid) end)

    {pid, agent_name}
  end

  test "uses the cached discovered context-limit when no config value is set" do
    test_pid = self()

    agent_name = "probe-anthropic-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "claude-3-opus-20240229"},
        context_limit_lookup: fn _provider, model_name ->
          send(test_pid, {:cache_lookup, model_name})
          {:openrouter, 200_000}
        end
      })

    info = Agent.get_public_info(pid, 1_000)
    assert info.context_limit == 200_000
    assert info.context_limit_source == :openrouter
    assert_received {:cache_lookup, "claude-3-opus-20240229"}

    Agent.terminate(pid)
  end

  test "falls back to the 128k default when cache, config, and provider default are all nil" do
    {pid, _agent_name} =
      start_probe_agent(%{
        name: "probe-missing-#{System.unique_integer([:positive])}",
        model: %{name: "claude-3-opus-20240229"},
        context_limit_lookup: fn _provider, _model -> nil end
      })

    info = Agent.get_public_info(pid, 1_000)
    assert info.context_limit == 128_000
    assert info.context_limit_source == :default

    Agent.terminate(pid)
  end

  test "uses the provider's `default-context-limit` when per-model config and cache are both nil" do
    # `[providers.pegasus]` in `test/data/config.toml` has
    # `default-context-limit = 512000` but no static entry for the
    # test model name, so per-model returns nil. The injected cache
    # lookup returns nil. The provider default kicks in.
    agent_name = "probe-provider-default-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "pegasus-default-only", provider: "pegasus"},
        context_limit_lookup: fn _provider, _model -> nil end
      })

    info = Agent.get_public_info(pid, 1_000)
    assert info.context_limit == 512_000
    assert info.context_limit_source == :provider_default

    Agent.terminate(pid)
  end

  test "per-model `context-limit` wins over provider-level `default-context-limit`" do
    # `pegasus-per-model-test` is a static-config entry under
    # `[providers.pegasus]` with `context-limit = 32000`. The
    # same provider has `default-context-limit = 512000`. The
    # per-model value wins per the resolution precedence.
    #
    # No `context_limit_lookup` is injected here: the per-model hit
    # short-circuits the resolution chain, so the cache tier is
    # captured but never invoked.
    agent_name = "probe-per-model-wins-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "pegasus-per-model-test", provider: "pegasus"}
      })

    info = Agent.get_public_info(pid, 1_000)
    assert info.context_limit == 32_000
    assert info.context_limit_source == :config

    Agent.terminate(pid)
  end

  test "propagates an Olla-extracted context-limit from the cache" do
    # The typhon /olla gateway returns `max_context_length` under
    # the `olla` namespace rather than at the model root, which
    # Discover now extracts as `{:olla, N}`. This pins the cache-tier
    # lookup → Init.initial_context_limit → Agent.llm_metrics.
    #
    # The model name resolves against the static config (the
    # anthropic entry) so the agent starts on the real path, while
    # `:provider` stays `"typhon"` as the cache key: per-model config
    # is nil for that name and the typhon provider has no
    # `default-context-limit`, so the injected Olla value is the one
    # that survives. Without the Olla branch, this case would fall
    # through to the 128k default.
    test_pid = self()

    agent_name = "probe-olla-#{System.unique_integer([:positive])}"

    {pid, _} =
      start_probe_agent(%{
        name: agent_name,
        model: %{name: "claude-3-opus-20240229", provider: "typhon"},
        context_limit_lookup: fn _provider, _model_name ->
          send(test_pid, {:cache_lookup, "typhon"})
          {:olla, 224_000}
        end
      })

    info = Agent.get_public_info(pid, 1_000)
    assert info.context_limit == 224_000
    assert info.context_limit_source == :olla
    assert_received {:cache_lookup, "typhon"}

    Agent.terminate(pid)
  end
end

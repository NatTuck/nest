defmodule Nest.Agents.AgentContextLimitTest do
  @moduledoc """
  Tests for the Agent's async context-limit probe.

  These tests stub `Req.get/2` with `Mimic.expect/3` and rely on
  Mimic's cross-process stub visibility (it uses persistent_term
  in non-async mode). They cannot run in the main `AgentTest`
  case, which is `async: true` — in async mode Mimic stubs are
  per-test-process and the probe runs in a `Task.Supervisor`
  child of the test, so the stub isn't seen.
  """

  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup :set_mimic_global
  setup :verify_on_exit!

  defp start_probe_agent(attrs) do
    agent_id = "probe-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Agent, attrs})

    # The agent swaps to MockClient via `:sys.replace_state/2` in
    # the chat path. These tests don't make LLM calls, but
    # swapping keeps the test surface consistent with `AgentTest`
    # and avoids a half-initialized state if a future test does
    # chat from the same agent.
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: MockClient}}
    end)

    MockClient.start_link(pid)

    on_exit(fn -> MockClient.stop(pid) end)

    {pid, agent_id}
  end

  test "probes the provider's /models endpoint when no config value is set" do
    Mimic.expect(Req, :get, fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "claude-3-opus-20240229", "context_length" => 200_000}
           ]
         }
       }}
    end)

    agent_id = "probe-anthropic-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

    {pid, _} =
      start_probe_agent(%{
        id: agent_id,
        model: %{name: "claude-3-opus-20240229"}
      })

    assert_receive {:chat_status, %{contextLimit: 200_000, contextLimitSource: :openrouter}},
                   2000

    Agent.terminate(pid)
  end

  test "broadcasts a chat:status with the discovered context limit" do
    Mimic.expect(Req, :get, fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "claude-3-opus-20240229", "context_length" => 200_000}
           ]
         }
       }}
    end)

    agent_id = "probe-bcast-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

    {pid, _} =
      start_probe_agent(%{
        id: agent_id,
        model: %{name: "claude-3-opus-20240229"}
      })

    assert_receive {:chat_status, %{contextLimit: 200_000, contextLimitSource: :openrouter}},
                   2000

    Agent.terminate(pid)
  end

  test "falls back to 128k default when the probe fails" do
    Mimic.expect(Req, :get, fn _url, _opts -> {:error, :econnrefused} end)

    {pid, _agent_id} =
      start_probe_agent(%{
        id: "probe-fail-#{System.unique_integer([:positive])}",
        model: %{name: "claude-3-opus-20240229"}
      })

    info = Agent.get_public_info(pid)
    assert info.context_limit == 128_000
    assert info.context_limit_source == :default

    Agent.terminate(pid)
  end
end

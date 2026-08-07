defmodule Nest.AgentsTest do
  @moduledoc """
  Tests for the `Nest.Agents` context module.

  `async: true`. The supervisor pid no longer does DB work
  during spawn — `Agent.pre_spawn/1` runs the agent-row and
  system-message inserts in the caller's pid, then the
  supervisor just spawns the GenServer. Each test gets its
  agent through `AgentTestHelpers.start_agent/1`, which
  handles Sandbox.allow + on_exit cleanup so no agent pid
  outlives its test (parallel-test ghost-pid leak fixed).
  """
  use Nest.DataCase, async: true

  import Eventually
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  # No `vid()` or `vocation_id_for_test/0` pre-fetch needed —
  # `AgentTestHelpers.start_agent/1` defaults its own vocation
  # (a real `upsert_vocation` row, shared across tests via
  # the `name` field) and registers the on_exit that calls
  # `Supervisor.stop_agent/1` to stop the agent pid.

  # No `await_models_refresh/0` needed: every test in this
  # file uses `qwen3.5-plus` (or other static-config model
  # names), which `Models.list/0` returns immediately from
  # `state.static_config.models` without waiting for the
  # auto-discovery scan to complete.

  # Provably unique agent name per call. Two tests running
  # concurrently (or sequentially) get different values, so the
  # supervisor's `Registry.via_tuple/1` lookup never collides.
  # `AgentTestHelpers.start_agent/1` honors a `:name` opt in
  # the attrs map.
  defp fresh_name, do: "agent#{System.unique_integer([:positive])}"

  describe "create_agent/1" do
    test "creates agent with model map" do
      {_pid, id} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      assert Regex.match?(~r/agent\d+/, id)

      {:ok, info} = Agents.get_info(id)
      assert model_name(info.model) == "qwen3.5-plus"
    end

    test "enriches model with provider from DotConfig when only :name is given" do
      # Callers (e.g. NewAgentPage) send just %{name: ...}; the API
      # looks up the provider so the chat header can render
      # "provider: model-name".
      {_pid, id} =
        AgentTestHelpers.start_agent(%{
          name: fresh_name(),
          model: %{name: "qwen3.5-plus"}
        })

      {:ok, info} = Agents.get_info(id)
      assert model_name(info.model) == "qwen3.5-plus"
      assert model_provider(info.model) == "model-studio"
    end

    test "starts the agent in :model_missing state when the model is unresolvable" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, name} =
            AgentTestHelpers.start_agent(%{
              name: fresh_name(),
              model: %{name: "custom-model", provider: nil}
            })

          assert is_binary(name)

          {:ok, info} = Agents.get_info(name)
          assert info.status == :model_missing
          assert model_name(info.model) == "custom-model"
        end)

      assert log =~ "could not resolve model"
    end
  end

  describe "get_info/1" do
    test "returns agent public info" do
      {_pid, name} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      {:ok, info} = Agents.get_info(name)
      assert info.name == name
      assert model_name(info.model) == "qwen3.5-plus"
      assert info.status == :idle
      assert info.message_count == 1
      assert info.partial == nil
    end

    test "returns error for non-existent agent" do
      assert Agents.get_info("nonexistent") == {:error, :not_found}
    end
  end

  describe "get_agent/1 error propagation" do
    test "returns {:error, reason} when Supervisor.get_agent/1 times out" do
      # Regression: `Supervisor.get_agent/1` returned
      # `{:error, {:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}}`
      # when `Models.list/0` was unresponsive, and the previous
      # `get_agent/1` only matched `{:ok, _}` / `{:error, :not_found}`,
      # raising `CaseClauseError`. The catch-all now propagates
      # the underlying reason so `AgentChannel.join/3` returns
      # `{:error, %{"reason" => "agent_unavailable"}}` cleanly.
      Supervisor
      |> expect(:get_agent, fn _name ->
        {:error, {:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}}
      end)

      assert {:error, {:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}} =
               Agents.get_agent("any-name")
    end

    test "returns {:error, reason} for arbitrary non-{:ok, pid} reasons" do
      Supervisor
      |> stub(:get_agent, fn _name -> {:error, :gen_server_timeout} end)

      assert Agents.get_agent("any-name") == {:error, :gen_server_timeout}
    end
  end

  describe "list_agents/0" do
    test "returns list of agent names" do
      {_pid1, id1} = AgentTestHelpers.start_agent(%{name: fresh_name()})
      {_pid2, id2} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      # This file is async; other tests' agents may be in the
      # registry too. Verify our two are present rather than
      # asserting a count.
      agents = Agents.list_agents()
      assert id1 in agents
      assert id2 in agents
    end
  end

  describe "list_agents_info/0" do
    test "returns list of agent info" do
      {_pid1, id1} = AgentTestHelpers.start_agent(%{name: fresh_name()})
      {_pid2, id2} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      agents_info = Agents.list_agents_info()
      assert Enum.any?(agents_info, fn info -> info.name == id1 end)
      assert Enum.any?(agents_info, fn info -> info.name == id2 end)
    end

    test "skips agents whose process dies during enumeration" do
      # Regression for the race where a sibling test's agent
      # is alive at `Supervisor.get_agent/1` time but exits
      # with `:crash` (or any non-graceful reason) between
      # the alive-check and the `GenServer.call`. The
      # catch clause in `Agents.fetch_public_info/1` and
      # `Agents.build_agent_data/1` must treat any exit as
      # `:not_found` rather than propagating the `:crash`
      # and aborting the whole listing.
      {_pid1, id1} = AgentTestHelpers.start_agent(%{name: fresh_name()})
      {_pid2, id2} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      # Stub `Agent.get_public_info/1` to `exit(:crash)` for
      # every agent — simulates the case where every
      # registered agent's GenServer crashed between the
      # supervisor lookup and the call landing. The widened
      # catch should swallow every `:crash` exit and the
      # list should come back empty.
      Mimic.copy(Nest.Agents.Agent)
      Mimic.stub(Nest.Agents.Agent, :get_public_info, fn _pid -> exit(:crash) end)

      assert Agents.list_agents_info() == []

      # Negative control: with the stub cleared, both
      # agents show up. This pins the test to the stub —
      # if the stub silently no-ops we'd see the agents
      # and the assertion above would still pass but for
      # the wrong reason.
      Mimic.stub(Nest.Agents.Agent, :get_public_info, fn pid ->
        GenServer.call(pid, :get_public_info)
      end)

      agents_info = Agents.list_agents_info()
      assert Enum.any?(agents_info, fn info -> info.name == id1 end)
      assert Enum.any?(agents_info, fn info -> info.name == id2 end)
    end
  end

  describe "chat/2" do
    test "sends message to agent" do
      {_pid, name} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      MockClient.set_response("Hi there!")

      :ok = Agents.chat(name, "Hello, agent!")

      assert eventually(
               fn ->
                 {:ok, info} = Agents.get_info(name)
                 info.message_count == 3
               end,
               timeout: 1000
             )
    end

    test "returns error for non-existent agent" do
      assert Agents.chat("nonexistent", "Hello") == {:error, :not_found}
    end
  end

  describe "retry_compaction/1" do
    test "dispatches :retry_compaction synchronously and replies :ok" do
      {agent_pid, id} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      # `Agents.retry_compaction/1` is now a `GenServer.call`
      # (synchronous). The reply is delivered only after the
      # handler has run, so no drain is needed — the call
      # itself is the sync barrier. A fresh `:idle` agent
      # triggers the handler's "retry_compaction ignored"
      # warning by design (handler coverage lives in
      # `test/nest/agents/agent/compaction/result_handler_test.exs`);
      # capture and discard per AGENTS.md.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Agents.retry_compaction(id)
        end)

      assert log =~ "retry_compaction ignored"
      assert Process.alive?(agent_pid)
    end

    test "returns error for non-existent agent" do
      assert Agents.retry_compaction("nonexistent") == {:error, :not_found}
    end
  end

  describe "compaction_loop_detected_ok/1" do
    test "dispatches :compaction_loop_detected_ok synchronously and replies :ok" do
      {agent_pid, id} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      # See `retry_compaction/1` above. Same handler-level
      # "ignored" warning at the wrong-status checkpoint;
      # capture and discard.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Agents.compaction_loop_detected_ok(id)
        end)

      assert log =~ "compaction_loop_detected_ok ignored"
      assert Process.alive?(agent_pid)
    end

    test "returns error for non-existent agent" do
      assert Agents.compaction_loop_detected_ok("nonexistent") == {:error, :not_found}
    end
  end

  describe "delete_agent/1" do
    test "removes agent" do
      {agent_pid, id} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      # `start_agent/1` links the test pid to the agent. The
      # link makes the test crash on unexpected agent death,
      # but `Agents.delete_agent/1` causes an intentional
      # shutdown — unlink first so the `:shutdown` signal
      # doesn't propagate here. (`start_agent/1`'s on_exit
      # also unlinks; unlinking here is redundant for cleanup
      # but is the only way to keep the test pid alive during
      # the explicit delete.)
      Process.unlink(agent_pid)
      :ok = Agents.delete_agent(id)

      assert Agents.get_info(id) == {:error, :not_found}
    end

    test "returns error for non-existent agent" do
      assert Agents.delete_agent("nonexistent") == {:error, :not_found}
    end
  end

  describe "change_model/2" do
    test "repairs an agent that started in :model_missing state" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, name} =
            AgentTestHelpers.start_agent(%{
              name: fresh_name(),
              model: %{name: "ghost-model", provider: nil}
            })

          {:ok, info} = Agents.get_info(name)
          assert info.status == :model_missing

          :ok =
            Agents.change_model(name, %{
              name: "qwen3.5-plus",
              provider: "model-studio"
            })

          {:ok, info} = Agents.get_info(name)
          assert info.status == :idle
          assert model_name(info.model) == "qwen3.5-plus"
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :not_found for an unknown agent" do
      assert Agents.change_model("nope", %{
               name: "qwen3.5-plus",
               provider: "model-studio"
             }) == {:error, :not_found}
    end

    test "proxies the agent's {:error, reason} reply verbatim" do
      {pid, name} = AgentTestHelpers.start_agent(%{name: fresh_name()})

      Agent
      |> stub(:set_model, fn _pid, _new_model -> {:error, :gen_server_timeout} end)

      assert Agents.change_model(name, %{
               name: "claude-3-opus-20240229",
               provider: "anthropic-provider"
             }) == {:error, :gen_server_timeout}

      # `Agent.get_public_info/1` is the proper introspection
      # call. The `:sys.get_state/1` "drain" was a code smell —
      # it bypassed the GenServer protocol and was only useful
      # for synchronizing on prior messages, which the chat
      # turn's not-yet-processing here doesn't need.
      assert model_name(Agent.get_public_info(pid).model) == "qwen3.5-plus"
    end
  end

  # The `model` field on `state` and on `info` arrives as
  # string keys for agents loaded from the JSONB column
  # (`Persistence.build_attrs_for_start/1` returns the
  # round-tripped Ecto `:map` shape) and as atom keys when the
  # caller passes atom-keyed attrs directly. Both shapes are
  # valid in the system; tests use this accessor to assert
  # without coupling to the source shape.
  defp model_name(model), do: model[:name] || model["name"]
  defp model_provider(model), do: model[:provider] || model["provider"]
end

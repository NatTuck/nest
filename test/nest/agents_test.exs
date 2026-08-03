defmodule Nest.AgentsTest do
  @moduledoc """
  Tests for the `Nest.Agents` context module.

  `async: true`. The supervisor pid no longer does DB work
  during spawn — `Agent.pre_spawn/1` runs the agent-row and
  system-message inserts in the caller's pid, then the
  supervisor just spawns the GenServer. Each test calls
  `Agents.create_agent/2` with an explicit `name:`, so the
  test pid owns the Sandbox checkout throughout the
  pre-spawn path.
  """
  use Nest.DataCase, async: true

  import Eventually
  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent, as: AgentGenServer
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    # `Agents.create_agent/2` → `Agent.pre_spawn/1` inserts an
    # `agents` row with `vocation_id` FK. The test pid resolves
    # a real `vocation_id` (inserting the row in its own
    # sandboxed transaction); each `Agents.create_agent/2` call
    # below passes it explicitly.
    Process.put(:test_vocation_id, AgentTestHelpers.vocation_id_for_test())
    on_exit(fn -> Process.delete(:test_vocation_id) end)

    # No `await_models_refresh/0` needed: every test in this
    # file uses `qwen3.5-plus` (or other static-config model
    # names), which `Models.list/0` returns immediately from
    # `state.static_config.models` without waiting for the
    # auto-discovery scan to complete.

    :ok
  end

  defp vid, do: Process.get(:test_vocation_id)

  # Provably unique agent name per call. Two tests running
  # concurrently (or sequentially) get different values, so the
  # supervisor's `Registry.via_tuple/1` lookup never collides.
  # Tests pass this via the `name:` opt to `Agents.create_agent/2`;
  # the model map keeps its real name (`qwen3.5-plus`) for
  # DotConfig resolution.
  defp fresh_name, do: "agent#{System.unique_integer([:positive])}"

  # The test model — real model name in `test/data/config.toml`,
  # so `enrich_model/1` finds the provider and the agent's
  # `init/1` can resolve the client.
  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}

  describe "create_agent/1" do
    test "creates agent with model map" do
      {:ok, id} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())

      assert Regex.match?(~r/agent\d+/, id)
      assert {:ok, info} = Agents.get_info(id)
      assert model_name(info.model) == "qwen3.5-plus"
    end

    test "enriches model with provider from DotConfig when only :name is given" do
      # Callers (e.g. NewAgentPage) send just %{name: ...}; the API
      # looks up the provider so the chat header can render
      # "provider: model-name".
      {:ok, id} =
        Agents.create_agent(%{name: "qwen3.5-plus"}, name: fresh_name(), vocation_id: vid())

      assert {:ok, info} = Agents.get_info(id)
      assert model_name(info.model) == "qwen3.5-plus"
      assert model_provider(info.model) == "model-studio"
    end

    test "starts the agent in :model_missing state when the model is unresolvable" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, name} =
            Agents.create_agent(
              %{name: "custom-model", provider: nil},
              name: fresh_name(),
              vocation_id: vid()
            )

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
      {:ok, name} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      {:ok, info} = Agents.get_info(name)
      assert info.name == name
      assert model_name(info.model) == "qwen3.5-plus"
      assert info.status == :idle
      assert info.message_count == 1
      assert info.partial == nil
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.get_info("nonexistent")
    end
  end

  describe "get_agent/1 error propagation" do
    test "returns {:error, reason} when Supervisor.get_agent/1 times out" do
      # Regression for the post-`change_model` channel crash:
      # `Supervisor.get_agent/1` returned
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

      assert {:error, :gen_server_timeout} = Agents.get_agent("any-name")
    end
  end

  describe "list_agents/0" do
    test "returns list of agent names" do
      {:ok, id1} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      {:ok, id2} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())

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
      {:ok, id1} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      {:ok, id2} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())

      agents_info = Agents.list_agents_info()
      assert Enum.any?(agents_info, fn info -> info.name == id1 end)
      assert Enum.any?(agents_info, fn info -> info.name == id2 end)
    end
  end

  describe "chat/2" do
    test "sends message to agent" do
      {:ok, name} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())

      {:ok, agent_pid} = Supervisor.get_agent(name)

      Sandbox.allow(Nest.Repo, self(), agent_pid)
      Mimic.allow(Nest.LLM.OpenAIClient, self(), agent_pid)
      Mimic.allow(Req, self(), agent_pid)
      Mimic.allow(Nest.DotConfig, self(), agent_pid)

      :sys.replace_state(agent_pid, fn state ->
        %{state | client_config: %{state.client_config | client: MockClient}}
      end)

      MockClient.start_link(agent_pid)
      Process.put(:nest_test_agent_pid, agent_pid)
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
      assert {:error, :not_found} = Agents.chat("nonexistent", "Hello")
    end
  end

  describe "retry_compaction/1" do
    test "sends :retry_compaction to the agent pid" do
      {:ok, id} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      {:ok, agent_pid} = Supervisor.get_agent(id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Agents.retry_compaction(id)
          :sys.get_state(agent_pid)
        end)

      assert log =~ "retry_compaction ignored"
      assert log =~ ":idle"
      assert log =~ ":compaction_failed"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.retry_compaction("nonexistent")
    end
  end

  describe "compaction_loop_detected_ok/1" do
    test "sends :compaction_loop_detected_ok to the agent pid" do
      {:ok, id} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      {:ok, agent_pid} = Supervisor.get_agent(id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Agents.compaction_loop_detected_ok(id)
          :sys.get_state(agent_pid)
        end)

      assert log =~ "compaction_loop_detected_ok ignored"
      assert log =~ ":idle"
      assert log =~ ":compaction_loop_detected"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.compaction_loop_detected_ok("nonexistent")
    end
  end

  describe "delete_agent/1" do
    test "removes agent" do
      {:ok, id} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      :ok = Agents.delete_agent(id)

      assert Agents.get_info(id) == {:error, :not_found}
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.delete_agent("nonexistent")
    end
  end

  describe "change_model/2" do
    test "repairs an agent that started in :model_missing state" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, name} =
            Agents.create_agent(
              %{name: "ghost-model", provider: nil},
              name: fresh_name(),
              vocation_id: vid()
            )

          {:ok, agent_pid} = Supervisor.get_agent(name)
          # Runtime DB writes (the `:set_model` handler's
          # `Persistence.update_agent_model/2`) need explicit
          # access to the test pid's connection.
          Sandbox.allow(Nest.Repo, self(), agent_pid)

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
      assert {:error, :not_found} =
               Agents.change_model("nope", %{
                 name: "qwen3.5-plus",
                 provider: "model-studio"
               })
    end

    test "proxies the agent's {:error, reason} reply verbatim" do
      {:ok, name} = Agents.create_agent(test_model(), name: fresh_name(), vocation_id: vid())
      {:ok, pid} = Supervisor.get_agent(name)

      AgentGenServer
      |> stub(:set_model, fn _pid, _new_model -> {:error, :gen_server_timeout} end)

      assert {:error, :gen_server_timeout} =
               Agents.change_model(name, %{
                 name: "claude-3-opus-20240229",
                 provider: "anthropic-provider"
               })

      assert model_name(:sys.get_state(pid).model) == "qwen3.5-plus"
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
